/*
 * SSTV 解码器（状态机 + 前端 + VIS + 逐行解码）。
 * 移植自 xdsopl/robot36 的 Decoder / Demodulator / Robot_36_Color（BSD 0-Clause,
 * Copyright 2024 Ahmet Inan <xdsopl@gmail.com>）；仅保留 Robot 36（其余模式表留扩展位）。
 *
 * 状态：SCANNING（只扫 VIS，不做逐行取样）→ LOCKED → DECODING → COMPLETE / ABORT。
 * 事件回调（由 Worker 转成 postMessage）：
 *   onVis(visCode, modeName, atSec)           命中 VIS（每次一张图）
 *   onInterrupted(decodedLines)               解码中新 VIS 出现 → 当前图按中断处理
 *   onRows(fromLine, toLineExclusive)         有新行写入图像缓冲（供渐进显示）
 *   onComplete(width, height)                 收满高度
 *   onAbort(reason, decodedLines)             连续丢同步 / EOF 未完成
 */

import { Demodulator, SYNC_WIDTH_5MS, SYNC_WIDTH_9MS, SYNC_WIDTH_20MS } from './Demodulator';
import { SimpleMovingAverage } from './dsp/Dsp';
import { Robot36 } from './Robot36';
import { ROBOT36 } from './ModeTable';
import { PixelBuffer } from './PixelBuffer';

interface VisOut {
  visCode: number;
  modeName: string;
  atSec: number;
}

export class Decoder {
  // —— 事件 ——
  onVis: ((visCode: number, modeName: string, atSec: number) => void) | null = null;
  onInterrupted: ((decodedLines: number) => void) | null = null;
  onRows: ((fromLine: number, toLineExclusive: number) => void) | null = null;
  onComplete: ((width: number, height: number) => void) | null = null;
  onAbort: ((reason: string, decodedLines: number) => void) | null = null;

  readonly imageBuffer: PixelBuffer;
  private pixelBuffer: PixelBuffer;
  private scratchBuffer: Float32Array;
  private scanLineBuffer: Float64Array;
  private demodBuffer: Float32Array;

  private sampleRate: number;
  private demodulator: Demodulator;
  private pulseFilter: SimpleMovingAverage;
  private pulseFilterLength: number;
  private pulseFilterDelay: number;
  private mode: Robot36;

  private currentSample: number = 0;
  private leaderBreakIndex: number = -1;
  private lastSyncPulseIndex: number = -1;
  private currentScanLineSamples: number;
  private lastFrequencyOffset: number = 0;
  private totalSamples: number = 0;
  private inputEnded: boolean = false;
  private locked: boolean = false;
  private missedSync: number = 0;

  private syncIndexes: Int32Array;
  private lineLengths: Int32Array;
  private frequencyOffsets: Float32Array;

  private scanLineMinSamples: number;
  private syncPulseToleranceSamples: number;
  private scanLineToleranceSamples: number;
  private leaderToneSamples: number;
  private leaderToneToleranceSamples: number;
  private transitionSamples: number;
  private visCodeBitSamples: number;
  private visCodeSamples: number;
  /** VIS 解析所需的前向样本数（break 之后要积累的量）；用于环形缓冲预留空间，保证 VIS 不在开头也能解析 */
  private visParseNeedSamples: number = 0;
  /** 扫描态环形缓冲移位时保留的样本数（覆盖整段 VIS 前置），避免缓冲饱和后无法解析 VIS */
  private visKeepSamples: number = 0;
  private visCodeBitFrequencies: Float64Array = new Float64Array(10);

  private static readonly MISS_SYNC_LIMIT = 12;
  /** 行周期自校准：锁定期实测的行周期样本数（0=尚未校准）。用于适配真实录音的非标准行周期。 */
  private calibratedLineSamples: number = 0;

  constructor(sampleRate: number, coarseOffsetHz: number = 0) {
    this.sampleRate = sampleRate;
    this.mode = new Robot36(sampleRate);
    this.demodulator = new Demodulator(sampleRate, coarseOffsetHz);

    const pulseFilterSamples = (Math.round(0.0025 * sampleRate) | 1);
    this.pulseFilterLength = pulseFilterSamples;
    this.pulseFilterDelay = (pulseFilterSamples - 1) / 2;
    this.pulseFilter = new SimpleMovingAverage(pulseFilterSamples);

    this.scanLineBuffer = new Float64Array(Math.round(7 * sampleRate));
    this.scratchBuffer = new Float32Array(Math.round(1.1 * sampleRate));
    this.demodBuffer = new Float32Array(Math.max(1, Math.round(0.25 * sampleRate)));
    this.pixelBuffer = new PixelBuffer(this.mode.width, 2);
    this.imageBuffer = new PixelBuffer(this.mode.width, this.mode.height);
    this.imageBuffer.line = -1;

    const lineCount = 4;
    const pulseCount = lineCount + 1;
    this.syncIndexes = new Int32Array(pulseCount);
    this.lineLengths = new Int32Array(lineCount);
    this.frequencyOffsets = new Float32Array(pulseCount);

    this.scanLineMinSamples = Math.round(0.05 * sampleRate);
    this.syncPulseToleranceSamples = Math.round(0.03 * sampleRate);
    this.scanLineToleranceSamples = Math.round(0.001 * sampleRate);
    this.leaderToneSamples = Math.round(0.3 * sampleRate);
    this.leaderToneToleranceSamples = Math.round(0.3 * 0.2 * sampleRate);
    this.transitionSamples = Math.round(0.0005 * sampleRate);
    this.visCodeBitSamples = Math.round(0.03 * sampleRate);
    this.visCodeSamples = Math.round(0.3 * sampleRate);

    this.visParseNeedSamples = this.leaderToneSamples + this.leaderToneToleranceSamples
      + this.visCodeSamples + this.visCodeBitSamples;
    this.visKeepSamples = this.leaderToneSamples + this.visParseNeedSamples + this.mode.scanLineSamples;

    this.currentScanLineSamples = this.mode.scanLineSamples;
    this.lineLengths.fill(this.currentScanLineSamples);
  }

  reset(): void {
    this.currentSample = 0;
    this.leaderBreakIndex = -1;
    this.lastSyncPulseIndex = -1;
    this.lastFrequencyOffset = 0;
    this.totalSamples = 0;
    this.inputEnded = false;
    this.locked = false;
    this.missedSync = 0;
    this.calibratedLineSamples = 0;
    this.imageBuffer.line = -1;
    this.lineLengths.fill(this.currentScanLineSamples);
    this.syncIndexes.fill(0);
    this.frequencyOffsets.fill(0);
  }

  private shiftSamples(shift: number): void {
    if (shift <= 0 || shift > this.currentSample) {
      return;
    }
    this.currentSample -= shift;
    if (this.leaderBreakIndex > 0) {
      this.leaderBreakIndex -= shift;
    }
    this.lastSyncPulseIndex -= shift;
    for (let i = 0; i < this.syncIndexes.length; i++) {
      this.syncIndexes[i] -= shift;
    }
    for (let i = 0; i < this.frequencyOffsets.length; i++) {
      this.frequencyOffsets[i] = this.frequencyOffsets[i];
    }
    this.scanLineBuffer.copyWithin(0, shift, shift + this.currentSample);
  }

  private copyLines(okay: boolean): void {
    if (!okay) {
      return;
    }
    if (this.imageBuffer.line < 0 || this.imageBuffer.line >= this.imageBuffer.height) {
      return;
    }
    const width = this.imageBuffer.width;
    const fromLine = this.imageBuffer.line;
    for (let row = 0; row < this.pixelBuffer.height && this.imageBuffer.line < this.imageBuffer.height; row++) {
      this.imageBuffer.pixels.set(
        this.pixelBuffer.pixels.subarray(row * width, row * width + width),
        this.imageBuffer.line * width
      );
      this.imageBuffer.line++;
    }
    const toLine = Math.min(this.imageBuffer.line, this.imageBuffer.height);
    if (toLine > fromLine && this.onRows !== null) {
      this.onRows(fromLine, toLine);
    }
    this.report(`copyLines ok: ${fromLine}..${toLine}`);
    this.report(`  sep=${this.mode.lastSeparator.toFixed(2)} ofs=${this.mode.lastOffset.toFixed(3)} syncIdx=${this.mode.lastSyncIdx} lvl0=${this.mode.lastLevel0.toFixed(3)} lumMid=${this.mode.lastLumMid.toFixed(3)} chrMid=${this.mode.lastChrMid.toFixed(3)} px0=${(this.pixelBuffer.pixels[0] >>> 0).toString(16)}`);
    if (this.imageBuffer.line >= this.imageBuffer.height) {
      // 一张图完成 → 回到 SCANNING（图像保留供 UI 显示/保存）
      this.locked = false;
      if (this.onComplete !== null) {
        this.onComplete(this.imageBuffer.width, this.imageBuffer.height);
      }
      this.imageBuffer.line = -1;
    }
  }

  /**
   * 统一的逐行解码入口：补偿同步检测的群延迟（pulseFilterDelay ≈1.25ms），
   * 使行内取样起点与发射端的“同步结束 + 肩”严格对齐（否则每行前几列会偏）。
   * 说明：这是对参考实现固有 1.25ms 提前量的精度修正，已在 README 记录。
   */
  private decodeAt(syncPulseIndex: number, lineLen: number, freqOffset: number): boolean {
    return this.mode.decodeScanLine(
      this.pixelBuffer, this.scratchBuffer, this.scanLineBuffer,
      syncPulseIndex, lineLen, freqOffset);
  }

  private meanOfInts(values: Int32Array): number {
    let sum = 0;
    for (let i = 0; i < values.length; i++) {
      sum += values[i];
    }
    return sum / values.length;
  }

  private stdDevOfInts(values: Int32Array, mean: number): number {
    let acc = 0;
    for (let i = 0; i < values.length; i++) {
      const d = values[i] - mean;
      acc += d * d;
    }
    return Math.sqrt(acc / values.length);
  }

  private meanOfFloats(values: Float32Array): number {
    let sum = 0;
    for (let i = 0; i < values.length; i++) {
      sum += values[i];
    }
    return sum / values.length;
  }

  private processSyncPulse(latestSyncIndex: number): boolean {
    // 滚动数组
    for (let i = 1; i < this.syncIndexes.length; i++) {
      this.syncIndexes[i - 1] = this.syncIndexes[i];
      this.frequencyOffsets[i - 1] = this.frequencyOffsets[i];
    }
    this.syncIndexes[this.syncIndexes.length - 1] = latestSyncIndex;
    this.frequencyOffsets[this.frequencyOffsets.length - 1] = this.demodulator.frequencyOffset;
    for (let i = 1; i < this.lineLengths.length; i++) {
      this.lineLengths[i - 1] = this.lineLengths[i];
    }
    this.lineLengths[this.lineLengths.length - 1] =
      this.syncIndexes[this.syncIndexes.length - 1] - this.syncIndexes[this.syncIndexes.length - 2];

    this.report(`sync latest=${latestSyncIndex} lineLen=${this.lineLengths[this.lineLengths.length - 1]} state=${this.locked}/${this.imageBuffer.line}`);
    if (this.lineLengths[0] === 0) {
      return false;
    }
    const mean = this.meanOfInts(this.lineLengths);
    const scanLineSamples = Math.round(mean);
    if (scanLineSamples < this.scanLineMinSamples || scanLineSamples > this.scanLineBuffer.length) {
      this.report(`sync: scanLineSamples=${scanLineSamples} out of range`);
      return false;
    }
    if (this.stdDevOfInts(this.lineLengths, mean) > this.scanLineToleranceSamples) {
      this.missedSync++;
      this.report(`sync: std too big (mean=${mean.toFixed(1)})`);
      return false;
    }
    this.missedSync = 0;

    const decoding = this.imageBuffer.line >= 0 && this.imageBuffer.line < this.imageBuffer.height;
    let pictureChanged = false;
    if (this.locked || decoding) {
      // 行周期自校准：首个已锁定行用实测行周期作为基准，并据此缩放行内段；
      // 之后各行只需与该基准保持一致（±1ms）。对标准 150ms 信号等价于原逻辑。
      if (this.calibratedLineSamples === 0) {
        this.applyLineCalibration(scanLineSamples);
      } else if (Math.abs(scanLineSamples - this.calibratedLineSamples) > this.scanLineToleranceSamples) {
        this.report(`sync: line length drift ${scanLineSamples} vs ${this.calibratedLineSamples}`);
        return false;
      }
    } else {
      // SCANNING：只做 VIS 检测，不做逐行取样
      this.report('sync: ignored (not locked)');
      return false;
    }

    if (this.lastSyncPulseIndex >= 0
      && Math.abs(this.lastSyncPulseIndex + scanLineSamples - latestSyncIndex) > this.syncPulseToleranceSamples) {
      pictureChanged = true;
    }

    const frequencyOffset = this.meanOfFloats(this.frequencyOffsets);
    // 时间轴漂移时回填缺失行
    if (pictureChanged && this.syncIndexes[0] >= scanLineSamples) {
      const endPulse = this.syncIndexes[0];
      const extrapolate = Math.floor(endPulse / scanLineSamples);
      const firstPulse = endPulse - extrapolate * scanLineSamples;
      for (let pulseIndex = firstPulse; pulseIndex < endPulse; pulseIndex += scanLineSamples) {
        this.copyLines(this.decodeAt(pulseIndex, scanLineSamples, frequencyOffset));
      }
    }
    const startIndex = pictureChanged ? 0 : this.lineLengths.length - 1;
    for (let i = startIndex; i < this.lineLengths.length; i++) {
      this.copyLines(this.decodeAt(this.syncIndexes[i], this.lineLengths[i], frequencyOffset));
      this.report(`   slot i=${i} idx=${this.syncIndexes[i]} ev=${this.mode.lastEvenFlag} chrMid=${this.mode.lastChrMid.toFixed(3)} c0=${this.mode.lastChrHead[0].toFixed(3)} c4=${this.mode.lastChrHead[4].toFixed(3)} y0=${this.mode.lastLumHead[0].toFixed(3)} y4=${this.mode.lastLumHead[4].toFixed(3)} row0=${this.mode.lastRow0Packed.toString(16)} imgLine=${this.imageBuffer.line}`);
    }
    this.lastSyncPulseIndex = this.syncIndexes[this.syncIndexes.length - 1];
    this.currentScanLineSamples = scanLineSamples;
    this.lastFrequencyOffset = frequencyOffset;
    this.shiftSamples(this.lastSyncPulseIndex + this.mode.getFirstPixelSampleIndex());
    return true;
  }

  private freeRun(limit: number): void {
    if (this.lastSyncPulseIndex < 0) {
      return;
    }
    this.copyLines(this.decodeAt(this.lastSyncPulseIndex, this.currentScanLineSamples, this.lastFrequencyOffset));
    this.lastSyncPulseIndex += this.currentScanLineSamples;
    this.missedSync++;
    this.report(`freeRun at ${this.lastSyncPulseIndex} missed=${this.missedSync} line=${this.imageBuffer.line}`);
    if (this.missedSync > limit) {
      const decodedLines = Math.max(0, this.imageBuffer.line);
      this.locked = false;
      this.imageBuffer.line = -1;
      this.missedSync = 0;
      if (this.onAbort !== null) {
        this.onAbort('信号弱或频偏', decodedLines);
      }
    }
  }

  /** 处理一段单声道 PCM（20ms 一块由调用方决定）。 */
  push(pcm: Float32Array, n: number): void {
    let offset = 0;
    while (offset < n) {
      const block = Math.min(this.demodBuffer.length, n - offset);
      const src = pcm.subarray(offset, offset + block);
      const detected = this.demodulator.processMono(src, block, this.demodBuffer);
      const width = this.demodulator.syncPulseWidth;
      const syncPulseOffset = this.demodulator.syncPulseOffset;
      let syncPulseIndex = this.currentSample + syncPulseOffset;
      for (let j = 0; j < block; j++) {
        this.scanLineBuffer[this.currentSample++] = this.demodBuffer[j];
        if (this.currentSample >= this.scanLineBuffer.length) {
          // 扫描态：一次移位留出足够前向空间（覆盖 break 之后需积累的 VIS 样本），
          // 否则缓冲饱和后 currentSample 贴尾、handleHeader 永远凑不满 → VIS 漏检。
          // 解码态：维持按行移位。
          const shift = this.locked
            ? this.currentScanLineSamples
            : Math.max(this.currentScanLineSamples, this.currentSample - this.visKeepSamples);
          this.shiftSamples(shift);
          syncPulseIndex -= shift;
        }
      }
      this.totalSamples += block;

      if (detected) {
        if (width === SYNC_WIDTH_9MS || width === SYNC_WIDTH_20MS) {
          this.leaderBreakIndex = syncPulseIndex;
        }
        if (width === SYNC_WIDTH_9MS || width === SYNC_WIDTH_20MS) {
          const latest = syncPulseIndex;
          this.processSyncPulse(latest);
        }
      } else {
        if (this.handleHeader() === false) {
          // 未命中 VIS：若已锁定且长时间无同步 → 自由运行/判定丢同步
          if (this.locked && this.currentSample > this.lastSyncPulseIndex + Math.floor(this.currentScanLineSamples * 5 / 4)) {
            this.freeRun(Decoder.MISS_SYNC_LIMIT);
          }
        }
      }
      offset += block;
    }
  }

  /** EOF：灌 1 秒零样本走同一管线；未完成的图按 ABORT（保留已解行）。 */
  finish(): void {
    if (this.inputEnded) {
      return;
    }
    this.inputEnded = true;
    const frames = Math.round(1.0 * this.sampleRate);
    const zeros = new Float32Array(Math.max(1, Math.floor(this.sampleRate / 50)));
    let done = 0;
    while (done < frames) {
      const k = Math.min(zeros.length, frames - done);
      zeros.fill(0, 0, k);
      this.push(zeros, k);
      done += k;
    }
    if (this.locked && this.imageBuffer.line > 0 && this.imageBuffer.line < this.imageBuffer.height) {
      // 用当前行时钟把剩余行继续解出（不依赖 free-run 分支判定）
      let guard = 0;
      while (this.locked && this.imageBuffer.line >= 0 && this.imageBuffer.line < this.imageBuffer.height
        && this.lastSyncPulseIndex + this.currentScanLineSamples <= this.currentSample && guard < 64) {
        this.copyLines(this.decodeAt(
          this.lastSyncPulseIndex, this.currentScanLineSamples, this.lastFrequencyOffset));
        this.lastSyncPulseIndex += this.currentScanLineSamples;
        guard++;
      }
    }
    if (this.locked && this.imageBuffer.line > 0 && this.imageBuffer.line < this.imageBuffer.height) {
      const decodedLines = this.imageBuffer.line;
      this.locked = false;
      this.imageBuffer.line = -1;
      if (this.onAbort !== null) {
        this.onAbort('文件结束，图像不完整', decodedLines);
      }
    }
  }

  /**
   * 行周期自校准 + 行内段缩放。
   * 真实内容时长 = 实测行周期 − 实测同步宽度；与名义内容（150ms−9ms）之比即为缩放系数，
   * 据此缩放 Y/色度窗口，避免窗口越过下一行同步而采错内容（标准信号缩放=1.0，行为不变）。
   */
  private applyLineCalibration(scanLineSamples: number): void {
    const rate = this.sampleRate;
    let syncSeconds = 0.009;
    const w = this.demodulator.syncPulseWidth;
    if (w === SYNC_WIDTH_5MS) {
      syncSeconds = 0.005;
    } else if (w === SYNC_WIDTH_20MS) {
      syncSeconds = 0.020;
    }
    const contentSamples = scanLineSamples - Math.round(syncSeconds * rate);
    const nominalContent = this.mode.scanLineSamples - Math.round(ROBOT36.syncPulseSeconds * rate);
    let scale = nominalContent > 0 ? contentSamples / nominalContent : 1;
    if (scale < 0.6 || scale > 1.4) {
      scale = 1;
    }
    this.mode.applyContentScale(scale);
    this.calibratedLineSamples = scanLineSamples;
    this.currentScanLineSamples = scanLineSamples;
  }

  private report(msg: string): void {
    if (this.debug !== null) {
      this.debug(msg);
    }
  }

  /** 诊断钩子（默认关闭） */
  debug: ((msg: string) => void) | null = null;

  /** VIS 解析（与参考实现一致；命中后把缓冲回退到该图第一个像素样本）。 */
  private handleHeader(): boolean {
    if (this.leaderBreakIndex < this.visCodeBitSamples + this.leaderToneToleranceSamples
      || this.currentSample < this.leaderBreakIndex + this.leaderToneSamples
        + this.leaderToneToleranceSamples + this.visCodeSamples + this.visCodeBitSamples) {
      return false;
    }
    const breakPulseIndex = this.leaderBreakIndex;
    this.leaderBreakIndex = -1;
    const halfBandWidth = (this.demodulator.whiteFrequency - this.demodulator.blackFrequency) / 2;
    const centerFrequency = 1900;
    const leaderToneFrequency = 1900;
    const toleranceFrequency = 50;

    let preBreakFreq = 0;
    for (let i = 0; i < this.leaderToneToleranceSamples; i++) {
      preBreakFreq += this.scanLineBuffer[breakPulseIndex - this.visCodeBitSamples - this.leaderToneToleranceSamples + i];
    }
    preBreakFreq = preBreakFreq * halfBandWidth / this.leaderToneToleranceSamples + centerFrequency;
    if (Math.abs(preBreakFreq - leaderToneFrequency) > toleranceFrequency) {
      this.report(`preBreak freq=${preBreakFreq.toFixed(1)}Hz`);
      return false;
    }

    let leaderFreq = 0;
    for (let i = this.transitionSamples; i < this.leaderToneSamples - this.leaderToneToleranceSamples; i++) {
      leaderFreq += this.scanLineBuffer[breakPulseIndex + i];
    }
    const leaderFreqOffset = leaderFreq / (this.leaderToneSamples - this.transitionSamples - this.leaderToneToleranceSamples);
    if (Math.abs(leaderFreqOffset * halfBandWidth + centerFrequency - leaderToneFrequency) > toleranceFrequency) {
      this.report('leader freq mismatch');
      return false;
    }

    const stopBitFrequency = 1200;
    const pulseThresholdValue = (((stopBitFrequency + leaderToneFrequency) / 2) - centerFrequency) / halfBandWidth;
    let visBeginIndex = breakPulseIndex + this.leaderToneSamples - this.leaderToneToleranceSamples;
    const visEndLimit = breakPulseIndex + this.leaderToneSamples + this.leaderToneToleranceSamples + this.visCodeBitSamples;
    if (visBeginIndex + this.pulseFilterLength >= this.scanLineBuffer.length) {
      return false;
    }
    for (let i = 0; i < this.pulseFilterLength; i++) {
      this.pulseFilter.avg(this.scanLineBuffer[visBeginIndex++] - leaderFreqOffset);
    }
    while (++visBeginIndex < visEndLimit) {
      if (this.pulseFilter.avg(this.scanLineBuffer[visBeginIndex] - leaderFreqOffset) < pulseThresholdValue) {
        break;
      }
    }
    if (visBeginIndex >= visEndLimit) {
      this.report('start bit not found');
      return false;
    }
    visBeginIndex -= this.pulseFilterDelay;
    const visEndIndex = visBeginIndex + this.visCodeSamples;
    if (visBeginIndex < 0 || visEndIndex + this.visCodeSamples >= this.scanLineBuffer.length) {
      return false;
    }

    for (let j = 0; j < 10; j++) {
      let acc = 0;
      for (let i = this.transitionSamples; i < this.visCodeBitSamples - this.transitionSamples; i++) {
        acc += this.scanLineBuffer[visBeginIndex + this.visCodeBitSamples * j + i] - leaderFreqOffset;
      }
      this.visCodeBitFrequencies[j] = acc * halfBandWidth / (this.visCodeBitSamples - 2 * this.transitionSamples) + centerFrequency;
    }
    if (Math.abs(this.visCodeBitFrequencies[0] - stopBitFrequency) > toleranceFrequency
      || Math.abs(this.visCodeBitFrequencies[9] - stopBitFrequency) > toleranceFrequency) {
      this.report(`start/stop bits=${this.visCodeBitFrequencies[0].toFixed(0)}/${this.visCodeBitFrequencies[9].toFixed(0)}Hz`);
      return false;
    }
    for (let i = 1; i < 9; i++) {
      const f = this.visCodeBitFrequencies[i];
      if (Math.abs(f - 1100) > toleranceFrequency && Math.abs(f - 1300) > toleranceFrequency) {
        this.report(`data bit ${i}=${f.toFixed(0)}Hz`);
        return false;
      }
    }
    let visCode = 0;
    for (let i = 0; i < 8; i++) {
      visCode |= (this.visCodeBitFrequencies[i + 1] < stopBitFrequency ? 1 : 0) << i;
    }
    let check = true;
    for (let i = 0; i < 8; i++) {
      check = check !== ((visCode & (1 << i)) !== 0);
    }
    visCode &= 127;
    if (!check || visCode !== this.mode.visCode) {
      this.report(`VIS code=${visCode} check=${check}`);
      return false;
    }

    // 找 VIS 停止位后的第一个行同步
    const syncThresholdValue = (((1200 + 1500) / 2) - centerFrequency) / halfBandWidth;
    let syncPulseIndex = visEndIndex - this.visCodeBitSamples;
    const syncPulseMaxIndex = visEndIndex + this.visCodeBitSamples;
    for (let i = 0; i < this.pulseFilterLength; i++) {
      this.pulseFilter.avg(this.scanLineBuffer[syncPulseIndex++] - leaderFreqOffset);
    }
    while (++syncPulseIndex < syncPulseMaxIndex) {
      if (this.pulseFilter.avg(this.scanLineBuffer[syncPulseIndex] - leaderFreqOffset) > syncThresholdValue) {
        break;
      }
    }
    if (syncPulseIndex >= syncPulseMaxIndex) {
      this.report('sync pulse after VIS not found');
      return false;
    }
    syncPulseIndex -= this.pulseFilterDelay;

    // —— 命中：若正在解码中，先按“中断”处理当前图 ——
    if (this.locked && this.imageBuffer.line > 0) {
      const decodedLines = this.imageBuffer.line;
      if (this.onInterrupted !== null) {
        this.onInterrupted(decodedLines);
      }
    }
    this.mode.resetState();
    this.imageBuffer.resize(this.mode.width, this.mode.height);
    this.imageBuffer.line = 0;
    this.calibratedLineSamples = 0;
    this.mode.applyContentScale(1);
    this.pixelBuffer.width = this.mode.width;
    this.pixelBuffer.height = 2;
    this.currentScanLineSamples = this.mode.scanLineSamples;
    this.lastFrequencyOffset = leaderFreqOffset;
    this.locked = true;
    this.missedSync = 0;

    this.lastSyncPulseIndex = syncPulseIndex + this.mode.getFirstSyncPulseIndex();
    const firstPixel = this.mode.getFirstPixelSampleIndex();
    for (let i = 0; i < this.syncIndexes.length; i++) {
      this.syncIndexes[i] = this.lastSyncPulseIndex + (i - (this.syncIndexes.length - 1)) * this.currentScanLineSamples;
    }
    this.lineLengths.fill(this.currentScanLineSamples);
    this.frequencyOffsets.fill(leaderFreqOffset);
    this.shiftSamples(this.lastSyncPulseIndex + firstPixel);

    if (this.onVis !== null) {
      this.onVis(visCode, this.mode.name, this.totalSamples / this.sampleRate);
    }
    return true;
  }
}