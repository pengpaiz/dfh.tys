/*
 * Robot 36 模式 —— 逐行解码，移植自 xdsopl/robot36 的 Robot_36_Color（BSD 0-Clause, Copyright 2024 Ahmet Inan）。
 *
 * 行结构：9ms 同步 + 3ms 肩 + 88ms Y(320px) + 4.5ms 分隔 + 1.5ms 肩 + 44ms 色度(320px) = 150ms/行。
 * 偶行携带 Y+V(色度)，奇行携带 Y+U；奇行结束时把两行配对输出（色度共享）。
 * 行内滤波：二阶 EMA，截止 = 输出像素数 / (2×通道样本数)，先正向、reset、再反向（零相位）；
 * 再按 0.5*(v - freqOffset + 1) 映射到 0–1，最近邻采样。
 */

import { ExponentialMovingAverage } from './dsp/Dsp';
import { RGB, YUV2RGB_PACKED } from './ColorConverter';
import { PixelBuffer } from './PixelBuffer';
import { ROBOT36 } from './ModeTable';

export class Robot36 {
  readonly name: string = ROBOT36.name;
  readonly visCode: number = ROBOT36.visCode;
  readonly width: number = ROBOT36.width;
  readonly height: number = ROBOT36.height;

  readonly scanLineSamples: number;
  private sampleRate: number;
  private syncPorchSeconds: number;
  private luminanceSeconds: number;
  private separatorSeconds: number;
  private porchSeconds: number;
  private chrominanceSeconds: number;
  private luminanceSamples: number = 0;
  private separatorSamples: number = 0;
  private chrominanceSamples: number = 0;
  private beginSamples: number = 0;
  private luminanceBeginSamples: number = 0;
  private separatorBeginSamples: number = 0;
  private chrominanceBeginSamples: number = 0;
  private endSamples: number = 0;
  private lowPassFilter: ExponentialMovingAverage = new ExponentialMovingAverage();
  private lastEven: boolean = false;
  /** 诊断：最近一行的分隔值、频偏、样本 level、奇偶与单行首像素 */
  lastSeparator: number = 0;
  lastOffset: number = 0;
  lastLevel0: number = 0;
  lastV: number = 0;
  lastEvenFlag: boolean = false;
  lastPx0: number = 0;
  lastSyncIdx: number = 0;
  lastLumMid: number = 0;
  lastChrMid: number = 0;
  /** 诊断：本行前 8 个 Y / 色度采样点（用于对齐行内时间轴） */
  lastLumHead: Float32Array = new Float32Array(8);
  lastChrHead: Float32Array = new Float32Array(8);
  /** 诊断：配对前的打包值（低 24 位 = Y|U|V） */
  lastEvenPacked: number = 0;
  lastRow0Packed: number = 0;
  lastRow1Packed: number = 0;

  constructor(sampleRate: number) {
    this.sampleRate = sampleRate;
    this.syncPorchSeconds = ROBOT36.syncPorchSeconds;
    this.luminanceSeconds = ROBOT36.luminanceSeconds;
    this.separatorSeconds = ROBOT36.separatorSeconds;
    this.porchSeconds = ROBOT36.porchSeconds;
    this.chrominanceSeconds = ROBOT36.chrominanceSeconds;
    const scanLineSeconds = ROBOT36.syncPulseSeconds + this.syncPorchSeconds + this.luminanceSeconds
      + this.separatorSeconds + this.porchSeconds + this.chrominanceSeconds;
    this.scanLineSamples = Math.round(scanLineSeconds * sampleRate);
    this.applyContentScale(1);
  }

  /**
   * 按比例缩放"行同步结束之后"的亮度/色度段（不改变 sync 起点语义）。
   * 用途：适配真实录音的非标准行周期；真实内容时长 = (实测行周期 − 实测同步宽度)。
   * 对标准 Robot 36 传入 1.0 时与世界标准完全一致。
   */
  applyContentScale(scale: number): void {
    const s = scale;
    const rate = this.sampleRate;
    this.luminanceBeginSamples = Math.round(this.syncPorchSeconds * s * rate);
    this.beginSamples = this.luminanceBeginSamples;
    this.luminanceSamples = Math.round(this.luminanceSeconds * s * rate);
    this.separatorBeginSamples = Math.round((this.syncPorchSeconds + this.luminanceSeconds) * s * rate);
    this.separatorSamples = Math.round(this.separatorSeconds * s * rate);
    this.chrominanceBeginSamples = Math.round(
      (this.syncPorchSeconds + this.luminanceSeconds + this.separatorSeconds + this.porchSeconds) * s * rate);
    this.chrominanceSamples = Math.round(this.chrominanceSeconds * s * rate);
    this.endSamples = Math.round(
      (this.syncPorchSeconds + this.luminanceSeconds + this.separatorSeconds + this.porchSeconds + this.chrominanceSeconds) * s * rate);
  }

  getFirstPixelSampleIndex(): number {
    return this.beginSamples;
  }

  getFirstSyncPulseIndex(): number {
    return 0;
  }

  resetState(): void {
    this.lastEven = false;
  }

  private freqToLevel(frequency: number, offset: number): number {
    return 0.5 * (frequency - offset + 1.0);
  }

  /**
   * 解码一行：把该行的像素写入 pixelBuffer。
   * 返回 true 表示完成了一个“行对”（此时 pixelBuffer.height = 2，可整体拷贝）。
   */
  decodeScanLine(
    pixelBuffer: PixelBuffer,
    scratchBuffer: Float32Array,
    scanLineBuffer: Float64Array,
    syncPulseIndex: number,
    scanLineSamples: number,
    frequencyOffset: number
  ): boolean {
    if (syncPulseIndex + this.beginSamples < 0 || syncPulseIndex + this.endSamples > scanLineBuffer.length) {
      return false;
    }
    // 分隔脉冲判奇偶：偶行分隔为 1500Hz（level≈-1），奇行为 2300Hz（level≈+1）
    let separator = 0;
    for (let i = 0; i < this.separatorSamples; i++) {
      separator += scanLineBuffer[syncPulseIndex + this.separatorBeginSamples + i];
    }
    separator /= this.separatorSamples;
    separator -= frequencyOffset;
    this.lastSeparator = separator;
    let even = separator < 0;
    if (separator < -1.1 || (separator > -0.9 && separator < 0.9) || separator > 1.1) {
      even = !this.lastEven; // 异常值：按上一行取反
    }
    this.lastEven = even;

    // 零相位二阶 EMA：正向 → reset → 反向
    this.lowPassFilter.cutoff(this.width, 2 * this.luminanceSamples, 2);
    this.lowPassFilter.reset();
    for (let i = this.beginSamples; i < this.endSamples; i++) {
      scratchBuffer[i] = this.lowPassFilter.avg(scanLineBuffer[syncPulseIndex + i]);
    }
    this.lowPassFilter.reset();
    for (let i = this.endSamples - 1; i >= this.beginSamples; i--) {
      scratchBuffer[i] = this.freqToLevel(this.lowPassFilter.avg(scratchBuffer[i]), frequencyOffset);
    }
    this.lastOffset = frequencyOffset;
    this.lastLevel0 = scratchBuffer[this.luminanceBeginSamples];
    this.lastV = scratchBuffer[this.chrominanceBeginSamples];
    this.lastSyncIdx = syncPulseIndex;
    this.lastLumMid = scratchBuffer[this.luminanceBeginSamples + Math.floor(this.luminanceSamples / 2)];
    this.lastChrMid = scratchBuffer[this.chrominanceBeginSamples + Math.floor(this.chrominanceSamples / 2)];
    for (let k = 0; k < 8; k++) {
      this.lastLumHead[k] = scratchBuffer[this.luminanceBeginSamples + Math.floor(k * this.luminanceSamples / this.width)];
      this.lastChrHead[k] = scratchBuffer[this.chrominanceBeginSamples + Math.floor(k * this.chrominanceSamples / this.width)];
    }

    for (let i = 0; i < this.width; i++) {
      const luminancePos = this.luminanceBeginSamples + Math.floor((i * this.luminanceSamples) / this.width);
      const chrominancePos = this.chrominanceBeginSamples + Math.floor((i * this.chrominanceSamples) / this.width);
      if (even) {
        // 偶行：存 (Y, 0, V)
        pixelBuffer.pixels[i] = RGB(scratchBuffer[luminancePos], 0, scratchBuffer[chrominancePos]);
        if (i === 0) {
          this.lastEvenPacked = pixelBuffer.pixels[i] & 0x00ffffff;
        }
      } else {
        const evenYUV = pixelBuffer.pixels[i];
        const oddYUV = RGB(scratchBuffer[luminancePos], scratchBuffer[chrominancePos], 0);
        // 行 0 = 偶行 Y + (U 来自奇行, V 来自偶行)；行 1 = 奇行 Y + 同一色度对
        pixelBuffer.pixels[i] = YUV2RGB_PACKED((evenYUV & 0x00ff00ff) | (oddYUV & 0x0000ff00));
        pixelBuffer.pixels[i + this.width] = YUV2RGB_PACKED((oddYUV & 0x00ffff00) | (evenYUV & 0x000000ff));
        if (i === 0) {
          this.lastRow0Packed = ((evenYUV & 0x00ff00ff) | (oddYUV & 0x0000ff00)) & 0x00ffffff;
          this.lastRow1Packed = ((oddYUV & 0x00ffff00) | (evenYUV & 0x000000ff)) & 0x00ffffff;
        }
      }
    }
    pixelBuffer.width = this.width;
    pixelBuffer.height = 2;
    this.lastEvenFlag = even;
    this.lastPx0 = pixelBuffer.pixels[0];
    return !even;
  }
}