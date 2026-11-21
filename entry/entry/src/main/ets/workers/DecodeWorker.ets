/*
 * 解码 Worker（P1）：读取 WAV → 20ms 分块 → 前端 + VIS + 逐行解码 → 回传事件。
 *
 * 与 UI 的协议（JSON 字符串）：
 *   in : { cmd: 'scan', uri, coarseOffsetHz } | { cmd: 'stop' }
 *   out: { type:'meta', sampleRate, channels, bits, frames, durationSec }
 *        { type:'progress', processedSec, totalSec, visCount }
 *        { type:'vis', visCode, modeName, atSec }
 *        { type:'rows', from, to }            新解出行（供渐进显示/进度）
 *        { type:'complete', width, height }
 *        { type:'abort', reason, decodedLines }
 *        { type:'interrupted', decodedLines } 解码中遇到新 VIS，当前图按中断处理
 *        { type:'done', visCount, stopped }
 *        { type:'error', message }
 */

import { worker, MessageEvents, ThreadWorkerGlobalScope } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { parseWavHeader, readFrames } from '../service/WavStreamReader';
import type { WavHeader } from '../service/WavStreamReader';
import { Decoder } from '../decoder/Decoder';

const parentPort: ThreadWorkerGlobalScope = worker.workerPort;

const BLOCK_SEC = 0.02;
const BLOCKS_PER_TICK = 10; // 每次让出事件循环前处理 0.2s 音频（同时作为出帧节拍，4×≈20fps）
/** 默认节拍：4× 速度出图（按绝对 deadline 控速，处理慢则追帧、绝不丢样本） */
const SPEED = 4; // 出图节拍：命中 VIS 开始逐行解码后按 4× 出图；命中前全速扫描以尽快定位 VIS 开头

interface ScanCmd {
  cmd: string;
  uri: string;
  coarseOffsetHz: number;
  /** 沙箱内的实时帧文件路径（由 UI 提供，Worker 写入） */
  framePath: string;
}

interface MetaOut {
  type: string;
  sampleRate: number;
  channels: number;
  bits: number;
  frames: number;
  durationSec: number;
}

interface ProgressOut {
  type: string;
  processedSec: number;
  totalSec: number;
  visCount: number;
}

interface VisOut {
  type: string;
  visCode: number;
  modeName: string;
  atSec: number;
}

interface RowsOut {
  type: string;
  from: number;
  to: number;
}

interface CompleteOut {
  type: string;
  width: number;
  height: number;
}

interface AbortOut {
  type: string;
  reason: string;
  decodedLines: number;
}

interface InterruptedOut {
  type: string;
  decodedLines: number;
}

interface DoneOut {
  type: string;
  visCount: number;
  stopped: boolean;
}

interface ErrorOut {
  type: string;
  message: string;
}

/** 帧通知（只走 JSON 字符串，二进制走沙箱文件） */
interface FrameOut {
  type: string;
  seq: number;
  /** 当前已解出的行数（<0 表示尚未进入解码） */
  rowsDone: number;
}

let bytes: Uint8Array | null = null;
let header: WavHeader | null = null;
let dec: Decoder | null = null;
let rate: number = 48000;
let startFrame: number = 0;
let totalFrames: number = 0;
let visCount: number = 0;
let stopped: boolean = false;
let scanning: boolean = false;
let wallStartMs: number = 0;
/** 是否已进入 4× 出图节拍（命中 VIS 前为全速扫描） */
let pacing: boolean = false;
/** 进入出图节拍时的音频帧位置（节拍基准，避免被全速扫描段拉偏） */
let paceStartFrame: number = 0;
/** 进度推送节流，避免全速扫描时刷爆 UI */
let lastProgressMs: number = 0;
/** 运行代号：每次 scan/stop 自增；旧任务的 setTimeout 链据此立即作废，避免串任务 */
let runId: number = 0;
let framePath: string = '';
let frameSeq: number = 0;
/** 复用同一块帧缓冲，避免每帧 307KB 反复分配造成 GC 压力 */
let frameBuf: ArrayBuffer | null = null;

function postMeta(): void {
  if (header === null) {
    return;
  }
  const out: MetaOut = {
    type: 'meta',
    sampleRate: header.sampleRate,
    channels: header.channels,
    bits: header.bits,
    frames: header.frameCount,
    durationSec: header.frameCount / header.sampleRate
  };
  parentPort.postMessage(JSON.stringify(out));
}

function postProgress(): void {
  const out: ProgressOut = {
    type: 'progress',
    processedSec: startFrame / rate,
    totalSec: totalFrames / rate,
    visCount
  };
  parentPort.postMessage(JSON.stringify(out));
}

function postDone(): void {
  const out: DoneOut = { type: 'done', visCount, stopped };
  parentPort.postMessage(JSON.stringify(out));
}

function postError(message: string): void {
  const out: ErrorOut = { type: 'error', message };
  parentPort.postMessage(JSON.stringify(out));
}

function scanTick(myRun: number): void {
  if (myRun !== runId || !scanning || bytes === null || header === null || dec === null) {
    return;
  }
  const blockFrames = Math.max(1, Math.round(BLOCK_SEC * rate));
  let processed = 0;
  while (processed < BLOCKS_PER_TICK) {
    if (stopped || startFrame >= totalFrames) {
      break;
    }
    const n = Math.min(blockFrames, totalFrames - startFrame);
    const pcm = readFrames(bytes, header, startFrame, n, 0);
    startFrame += n;
    processed++;
    dec.push(pcm, n);
  }
  // 进度节流：全速扫描阶段不必每个节拍都刷 UI
  const nowMs = Date.now();
  if (nowMs - lastProgressMs >= 100) {
    lastProgressMs = nowMs;
    postProgress();
  }
  // 每个节拍主动推一帧（仅进入解码后）：与解码节奏绑定，保证 UI 渐进刷新，不再依赖 UI 轮询
  postFrame();
  if (stopped || startFrame >= totalFrames) {
    scanning = false;
    if (!stopped) {
      dec.finish();
    }
    postProgress();
    postDone();
    return;
  }
  // 命中 VIS（imageBuffer.line>=0）那一刻起启用 4× 出图节拍；此前**全速扫描**以尽快找到 VIS 开头
  if (!pacing && dec.imageBuffer.line >= 0) {
    pacing = true;
    paceStartFrame = startFrame;
    wallStartMs = Date.now();
  }
  let delay = 0;
  if (pacing) {
    const targetMs = wallStartMs + ((startFrame - paceStartFrame) / rate) * 1000 / SPEED;
    delay = Math.max(0, Math.round(targetMs - Date.now()));
  }
  setTimeout((): void => {
    scanTick(myRun);
  }, delay);
}

/**
 * 把当前图像缓冲整帧写入沙箱文件（BGRA_8888，307KB），并只发一条小 JSON 通知。
 * 说明：ArkTS Worker 对携带 ArrayBuffer 的对象消息支持不稳定，故二进制一律走文件。
 */
function postFrame(): void {
  // 尚未进入解码（line<0，如扫描 VIS 阶段）就不推帧，避免 UI 拿到全透明帧
  if (dec === null || framePath === '' || dec.imageBuffer.line < 0) {
    return;
  }
  try {
    const img = dec.imageBuffer;
    const len = img.width * img.height;
    if (frameBuf === null || frameBuf.byteLength !== len * 4) {
      frameBuf = new ArrayBuffer(len * 4);
    }
    new Int32Array(frameBuf).set(img.pixels);
    const tmpPath = framePath + '.tmp';
    const f = fs.openSync(tmpPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, frameBuf);
    fs.closeSync(f);
    // 原子改名：避免 UI 读到“写了一半/被清空”的文件（否则会漏帧或 createPixelMap 崩溃）
    fs.renameSync(tmpPath, framePath);
    frameSeq++;
    const out: FrameOut = { type: 'frame', seq: frameSeq, rowsDone: img.line };
    parentPort.postMessage(JSON.stringify(out));
  } catch (e) {
    if (e instanceof Error) {
      postError(`写帧文件失败：${e.message}`);
    }
  }
}

function beginScan(cmd: ScanCmd): void {
  runId++;
  const myRun = runId;
  try {
    const stat = fs.statSync(cmd.uri);
    const buf = new ArrayBuffer(stat.size);
    const file = fs.openSync(cmd.uri, fs.OpenMode.READ_ONLY);
    fs.readSync(file.fd, buf);
    fs.closeSync(file);
    bytes = new Uint8Array(buf);
    header = parseWavHeader(bytes);
    rate = header.sampleRate;
    totalFrames = header.frameCount;
    startFrame = 0;
    visCount = 0;
    stopped = false;
    framePath = cmd.framePath;
    frameSeq = 0;

    const decoder = new Decoder(rate, cmd.coarseOffsetHz);
    decoder.onVis = (visCode: number, modeName: string, atSec: number): void => {
      visCount++;
      const out: VisOut = { type: 'vis', visCode, modeName, atSec };
      parentPort.postMessage(JSON.stringify(out));
    };
    decoder.onRows = (from: number, to: number): void => {
      // 只报行号（像素统一由 snapshot 整帧下发，避免两条链路互相干扰）
      const out: RowsOut = { type: 'rows', from, to };
      parentPort.postMessage(JSON.stringify(out));
    };
    decoder.onComplete = (width: number, height: number): void => {
      const out: CompleteOut = { type: 'complete', width, height };
      parentPort.postMessage(JSON.stringify(out));
      postFrame(); // 完成后补发一次终帧
    };
    decoder.onAbort = (reason: string, decodedLines: number): void => {
      const out: AbortOut = { type: 'abort', reason, decodedLines };
      parentPort.postMessage(JSON.stringify(out));
    };
    decoder.onInterrupted = (decodedLines: number): void => {
      const out: InterruptedOut = { type: 'interrupted', decodedLines };
      parentPort.postMessage(JSON.stringify(out));
    };
    dec = decoder;

    postMeta();
    wallStartMs = Date.now();
    pacing = false;
    paceStartFrame = 0;
    lastProgressMs = 0;
    scanning = true;
    scanTick(myRun);
  } catch (e) {
    scanning = false;
    if (e instanceof Error) {
      postError(e.message);
    } else {
      postError('打开文件失败');
    }
  }
}

parentPort.onmessage = (e: MessageEvents): void => {
  const raw = e.data as string;
  let cmd: ScanCmd;
  try {
    cmd = JSON.parse(raw) as ScanCmd;
  } catch (parseErr) {
    postError('无法解析 Worker 指令');
    return;
  }
  if (cmd.cmd === 'snapshot') {
    postFrame();
    return;
  }
  if (cmd.cmd === 'stop') {
    stopped = true;
    runId++;
    return;
  }
  if (cmd.cmd === 'scan') {
    stopped = false;
    beginScan(cmd);
  }
};