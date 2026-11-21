/*
 * Look4Sat. 通联录音（应用内录音，保存为 WAV，保存在本机应用目录）。
 *
 * 用 AudioKit 的 AudioCapturer 采集 PCM（16-bit / 16kHz / 单声道），
 * 边录边写 WAV 的 data 段，停止时回填 RIFF 头；同时实时计算 RMS 电平，
 * 供详情页声波模块显示真实幅度。
 *
 * 文件落在 context.filesDir/recordings/ 下——应用自己的目录不需要存储权限。
 *
 * 注意（来自开发指南）：
 * - 必须在前台启动录制；后台启动会失败；持续/后台录制需要长时任务，
 *   本实现只在详情页前台录制，页面退出即停止并释放麦克风。
 * - 权限：ohos.permission.MICROPHONE（user_grant），
 *   需在 module.json5 声明 reason/usedScene，并在运行时申请。
 */

import { audio } from '@kit.AudioKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from './Logger';

const MIC_PERMISSION: Permissions[] = ['ohos.permission.MICROPHONE'];
const REC_DIR = 'recordings';
const SAMPLE_RATE = 16000;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;
const WAV_HEADER_BYTES = 44;
/** 每次读取的 PCM 字节数（2048 字节 ≈ 64ms @16kHz/16bit） */
const BLOCK_BYTES = 2048;
/** 保留最近的电平数量（与详情页声波条数一致） */
const LEVEL_COUNT = 32;
/** 瀑布图频带数量 */
const BAND_COUNT = 16;
/** 瀑布图保留的历史帧数 */
const SPECTRUM_FRAMES = 64;
/** Goertzel 分析窗长度（样本数） */
const FFT_SIZE = 1024;

export class AudioRecorder {
  private static instanceValue: AudioRecorder | null = null;
  private capturer: audio.AudioCapturer | null = null;
  private file: fs.File | null = null;
  private recording: boolean = false;
  private startTs: number = 0;
  private savedName: string = '';
  private dataBytes: number = 0;
  private readTask: Promise<void> | null = null;
  private levels: number[] = [];
  /** 最近 SPECTRUM_FRAMES 帧、每帧 BAND_COUNT 个频带能量（0~1） */
  private spectrum: number[][] = [];
  private static hannCache: number[] = [];

  static getInstance(): AudioRecorder {
    if (AudioRecorder.instanceValue === null) {
      AudioRecorder.instanceValue = new AudioRecorder();
    }
    return AudioRecorder.instanceValue;
  }

  isRecording(): boolean {
    return this.recording;
  }

  elapsedMillis(): number {
    return this.recording ? Date.now() - this.startTs : 0;
  }

  /** 最近一次保存的文件名（不含目录） */
  lastSavedName(): string {
    return this.savedName;
  }

  /** 最近 LEVEL_COUNT 个真实电平（0~1，旧→新） */
  recentLevels(): number[] {
    return this.levels.slice();
  }

  /** 最近 SPECTRUM_FRAMES 帧频谱（旧→新，每帧 BAND_COUNT 个 0~1 能量） */
  recentSpectrum(): number[][] {
    return this.spectrum;
  }

  /** 申请麦克风权限（user_grant）。 */
  static async ensurePermission(context: common.Context): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const res = await atManager.requestPermissionsFromUser(context, MIC_PERMISSION);
      for (let i = 0; i < res.authResults.length; i++) {
        if (res.authResults[i] === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
          return false;
        }
      }
      return res.authResults.length > 0;
    } catch (e) {
      Logger.error('AudioRecorder', `request permission failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /** 开始录音，返回文件名；失败会抛出异常（调用方提示用户）。 */
  async start(context: common.Context): Promise<string> {
    if (this.recording) {
      return this.savedName;
    }
    const dir = `${context.filesDir}/${REC_DIR}`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
    }
    const name = `rec_${AudioRecorder.stamp()}.wav`;
    const path = `${dir}/${name}`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    this.file = file;
    this.dataBytes = 0;
    this.levels = [];
    this.spectrum = [];
    let capturer: audio.AudioCapturer | null = null;
    try {
      // 先写 44 字节占位头，停止时回填长度
      fs.writeSync(file.fd, AudioRecorder.wavHeader(0));
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        capturerInfo: {
          source: audio.SourceType.SOURCE_TYPE_MIC,
          capturerFlags: 0
        }
      };
      const created: audio.AudioCapturer = await audio.createAudioCapturer(options);
      capturer = created;
      this.capturer = created;
      await created.start();
      this.recording = true;
      this.startTs = Date.now();
      this.savedName = name;
      this.readTask = this.readLoop(created, file);
      return name;
    } catch (e) {
      // 启动失败：回滚已占用的采集器与文件句柄，避免麦克风/文件句柄泄漏
      this.recording = false;
      this.capturer = null;
      this.file = null;
      if (capturer !== null) {
        try {
          await capturer.release();
        } catch (err) {
          Logger.error('AudioRecorder', `release after failed start: ${JSON.stringify(err)}`);
        }
      }
      try {
        fs.closeSync(file);
      } catch (err) {
        // 忽略关闭失败
      }
      // ArkTS 限制 throw 只能抛 Error 及其子类：把任意异常归一成 Error，保留原始信息
      const err: Error = e instanceof Error ? e : new Error(String(e));
      throw err;
    }
  }

  /** 停止录音并释放资源；返回本次保存的文件名（未在录制则返回空串）。 */
  async stop(): Promise<string> {
    const wasRecording = this.recording;
    this.recording = false;
    const file = this.file;
    const capturer = this.capturer;
    const name = wasRecording ? this.savedName : '';
    this.capturer = null;
    try {
      if (capturer !== null) {
        if (wasRecording) {
          await capturer.stop();
        }
        await capturer.release();
      }
    } catch (e) {
      Logger.error('AudioRecorder', `stop/release failed: ${JSON.stringify(e)}`);
    }
    // 等读取循环退出后再回填 WAV 头，避免并发写同一个 fd
    if (this.readTask !== null) {
      try {
        await this.readTask;
      } catch (e) {
        // 读取循环退出异常无需向上传播
      }
      this.readTask = null;
    }
    if (file !== null) {
      if (wasRecording) {
        try {
          fs.writeSync(file.fd, AudioRecorder.wavHeader(this.dataBytes), {
            offset: 0,
            length: WAV_HEADER_BYTES
          });
        } catch (e) {
          Logger.error('AudioRecorder', `patch wav header failed: ${JSON.stringify(e)}`);
        }
      }
      try {
        fs.closeSync(file);
      } catch (e) {
        // 忽略关闭失败
      }
    }
    this.file = null;
    return name;
  }

  /** 页面退出时调用：正在录就先停掉，避免长期占用麦克风。 */
  async releaseIfRecording(): Promise<void> {
    if (this.recording) {
      await this.stop();
    }
  }

  /** 删除本机全部录音文件（供"清除本机数据"使用）。返回删除的文件数。 */
  static clearRecordings(context: common.Context): number {
    const dir = `${context.filesDir}/${REC_DIR}`;
    let removed = 0;
    try {
      if (!fs.accessSync(dir)) {
        return 0;
      }
      const names = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          fs.unlinkSync(`${dir}/${names[i]}`);
          removed++;
        } catch (e) {
          // 单个文件删除失败不影响其它
        }
      }
    } catch (e) {
      Logger.error('AudioRecorder', `clearRecordings failed: ${JSON.stringify(e)}`);
    }
    return removed;
  }

  /** 持续读取 PCM：写 data 段并计算 RMS 电平，直到 recording 变为 false。 */
  private async readLoop(capturer: audio.AudioCapturer, file: fs.File): Promise<void> {
    while (this.recording) {
      try {
        const buffer: ArrayBuffer = await capturer.read(BLOCK_BYTES, true);
        if (!this.recording) {
          break;
        }
        if (buffer.byteLength > 0) {
          fs.writeSync(file.fd, buffer);
          this.dataBytes += buffer.byteLength;
          this.pushLevel(buffer);
          this.pushSpectrum(buffer);
        }
      } catch (e) {
        // 停止时 read 会抛错，正常退出
        break;
      }
    }
  }

  /** 把一块 S16LE PCM 的 RMS 映射成 0~1 的显示电平（-60dB~0dB）。 */
  private pushLevel(buffer: ArrayBuffer): void {
    const count = Math.floor(buffer.byteLength / 2);
    if (count <= 0) {
      return;
    }
    const samples = new Int16Array(buffer, 0, count);
    let sum = 0;
    for (let i = 0; i < count; i++) {
      const s = samples[i];
      sum += s * s;
    }
    const rms = Math.sqrt(sum / count) / 32768;
    const db = 20 * Math.log10(Math.max(rms, 0.000001));
    const level = Math.max(0.04, Math.min(1, (db + 60) / 60));
    this.levels.push(level);
    while (this.levels.length > LEVEL_COUNT) {
      this.levels.shift();
    }
  }

  /** 计算一帧的对数频谱（BAND_COUNT 个 0~1 能量），供瀑布图显示。 */
  private pushSpectrum(buffer: ArrayBuffer): void {
    const count = Math.floor(buffer.byteLength / 2);
    if (count < 64) {
      return;
    }
    const samples = new Int16Array(buffer, 0, count);
    const n = Math.min(count, FFT_SIZE);
    const row: number[] = [];
    for (let b = 0; b < BAND_COUNT; b++) {
      const ratio = BAND_COUNT > 1 ? b / (BAND_COUNT - 1) : 0;
      // 150Hz ~ 7kHz 对数分布，覆盖 SSTV 的主要能量范围
      const freq = 150 * Math.pow(7000 / 150, ratio);
      row.push(AudioRecorder.bandLevel(samples, n, freq));
    }
    this.spectrum.push(row);
    while (this.spectrum.length > SPECTRUM_FRAMES) {
      this.spectrum.shift();
    }
  }

  /** Goertzel 单频点能量，返回 0~1（-65dB~0dB）。 */
  private static bandLevel(samples: Int16Array, n: number, freq: number): number {
    const win = AudioRecorder.hann(n);
    const w = 2 * Math.PI * freq / SAMPLE_RATE;
    const coeff = 2 * Math.cos(w);
    let s1 = 0;
    let s2 = 0;
    for (let i = 0; i < n; i++) {
      const s0 = samples[i] / 32768 * win[i] + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    const mag = Math.sqrt(Math.max(0, power)) / (n / 2);
    const db = 20 * Math.log10(Math.max(mag, 0.000001));
    return Math.max(0, Math.min(1, (db + 65) / 65));
  }

  /** 预计算 Hann 窗，避免每帧重复三角函数。 */
  private static hann(n: number): number[] {
    if (AudioRecorder.hannCache.length === n) {
      return AudioRecorder.hannCache;
    }
    const arr: number[] = [];
    for (let i = 0; i < n; i++) {
      arr.push(0.5 - 0.5 * Math.cos(2 * Math.PI * i / (n - 1)));
    }
    AudioRecorder.hannCache = arr;
    return arr;
  }

  /** 生成 44 字节 WAV（PCM）头。 */
  private static wavHeader(dataLen: number): ArrayBuffer {
    const buf = new ArrayBuffer(WAV_HEADER_BYTES);
    const view = new DataView(buf);
    AudioRecorder.writeAscii(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataLen, true);
    AudioRecorder.writeAscii(view, 8, 'WAVE');
    AudioRecorder.writeAscii(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, CHANNELS, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8, true);
    view.setUint16(32, CHANNELS * BITS_PER_SAMPLE / 8, true);
    view.setUint16(34, BITS_PER_SAMPLE, true);
    AudioRecorder.writeAscii(view, 36, 'data');
    view.setUint32(40, dataLen, true);
    return buf;
  }

  private static writeAscii(view: DataView, offset: number, text: string): void {
    for (let i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  }

  /** 文件名用的时间戳：yyyyMMdd_HHmmss */
  private static stamp(): string {
    const d = new Date();
    const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}_${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
  }
}
