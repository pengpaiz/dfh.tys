/*
 * SSTV demodulator front-end — ported from xdsopl/robot36 (Java).
 *
 * Original: Copyright 2024 Ahmet Inan <xdsopl@gmail.com>  (BSD 0-Clause)
 *
 * 中心频率 1900Hz（可加粗频偏），黑 1500 / 白 2300 / 同步 1200；
 * 归一化频率 = (f - center) * 2 / (white - black) = 2*(f-1900)/800。
 * 复混频到零中频 → 2ms / Kaiser β=2 / 截止 900Hz 复 FIR → 逐样本相位差鉴频。
 * 同步：载波值 2.5ms 滑动平均 + 施密特（阈值 1275/1350Hz）→ 按脉宽分 5/9/20ms。
 */

import { Cx, Phasor, SimpleMovingAverage, Delay, ComplexConvolution, FrequencyModulation, SchmittTrigger, Kaiser, Filter } from './dsp/Dsp';

export const SYNC_WIDTH_5MS = 0;
export const SYNC_WIDTH_9MS = 1;
export const SYNC_WIDTH_20MS = 2;

export const SYNC_PULSE_FREQ = 1200;
export const BLACK_FREQ = 1500;
export const WHITE_FREQ = 2300;

export class Demodulator {
  readonly syncPulseFrequency: number = SYNC_PULSE_FREQ;
  readonly blackFrequency: number = BLACK_FREQ;
  readonly whiteFrequency: number = WHITE_FREQ;

  syncPulseWidth: number = SYNC_WIDTH_5MS;
  syncPulseOffset: number = 0;
  frequencyOffset: number = 0;

  private syncPulseFilter: SimpleMovingAverage;
  private baseBandLowPass: ComplexConvolution;
  private frequencyModulation: FrequencyModulation;
  private syncPulseTrigger: SchmittTrigger;
  private baseBandOscillator: Phasor;
  private syncPulseValueDelay: Delay;
  private baseBand: Cx = new Cx();
  private scanLineBandwidth: number;
  private centerFrequency: number;
  private syncPulseFrequencyValue: number;
  private syncPulseFrequencyTolerance: number;
  private syncPulse5msMinSamples: number;
  private syncPulse5msMaxSamples: number;
  private syncPulse9msMaxSamples: number;
  private syncPulse20msMaxSamples: number;
  private syncPulseFilterDelay: number;
  private syncPulseCounter: number = 0;

  constructor(sampleRate: number, coarseOffsetHz: number = 0) {
    this.scanLineBandwidth = this.whiteFrequency - this.blackFrequency;
    this.frequencyModulation = new FrequencyModulation(this.scanLineBandwidth, sampleRate);

    const syncPulse5msSeconds = 0.005;
    const syncPulse9msSeconds = 0.009;
    const syncPulse20msSeconds = 0.020;
    const syncPulse5msMinSeconds = syncPulse5msSeconds / 2;
    const syncPulse5msMaxSeconds = (syncPulse5msSeconds + syncPulse9msSeconds) / 2;
    const syncPulse9msMaxSeconds = (syncPulse9msSeconds + syncPulse20msSeconds) / 2;
    const syncPulse20msMaxSeconds = syncPulse20msSeconds + syncPulse5msSeconds;
    this.syncPulse5msMinSamples = Math.round(syncPulse5msMinSeconds * sampleRate);
    this.syncPulse5msMaxSamples = Math.round(syncPulse5msMaxSeconds * sampleRate);
    this.syncPulse9msMaxSamples = Math.round(syncPulse9msMaxSeconds * sampleRate);
    this.syncPulse20msMaxSamples = Math.round(syncPulse20msMaxSeconds * sampleRate);

    const syncPulseFilterSamples = (Math.round((syncPulse5msSeconds / 2) * sampleRate) | 1);
    this.syncPulseFilterDelay = (syncPulseFilterSamples - 1) / 2;
    this.syncPulseFilter = new SimpleMovingAverage(syncPulseFilterSamples);
    this.syncPulseValueDelay = new Delay(syncPulseFilterSamples);

    const lowestFrequency = 1000;
    const highestFrequency = 2800;
    const cutoffFrequency = (highestFrequency - lowestFrequency) / 2;
    const baseBandLowPassSamples = (Math.round(0.002 * sampleRate) | 1);
    this.baseBandLowPass = new ComplexConvolution(baseBandLowPassSamples);
    const kaiser = new Kaiser();
    for (let i = 0; i < baseBandLowPassSamples; i++) {
      this.baseBandLowPass.taps[i] =
        kaiser.window(2.0, i, baseBandLowPassSamples) * Filter.lowPass(cutoffFrequency, sampleRate, i, baseBandLowPassSamples);
    }

    // 粗频偏：把混频中心整体平移（门限/归一化随之保持相对不变）
    this.centerFrequency = (lowestFrequency + highestFrequency) / 2 + coarseOffsetHz;
    this.baseBandOscillator = new Phasor(-this.centerFrequency, sampleRate);

    this.syncPulseFrequencyValue = this.normalizeNominal(SYNC_PULSE_FREQ);
    this.syncPulseFrequencyTolerance = 50 * 2 / this.scanLineBandwidth;

    const syncPorchFrequency = 1500;
    const syncHighFrequency = (SYNC_PULSE_FREQ + syncPorchFrequency) / 2;
    const syncLowFrequency = (SYNC_PULSE_FREQ + syncHighFrequency) / 2;
    this.syncPulseTrigger = new SchmittTrigger(
      this.normalizeNominal(syncLowFrequency),
      this.normalizeNominal(syncHighFrequency)
    );
  }

  /**
   * 标称归一化：始终以 1900Hz 为参照（与参考实现一致）。
   * 粗频偏把混频中心整体平移，标称门限随之“在偏移中抵消”，因此这里不使用 centerFrequency。
   */
  private normalizeNominal(frequency: number): number {
    return (frequency - 1900) * 2 / this.scanLineBandwidth;
  }

  /** 单声道：处理 n 个样本，解调值写入 out[0..n)，返回是否检测到同步脉冲。 */
  processMono(input: Float32Array, n: number, out: Float32Array): boolean {
    let detected = false;
    for (let i = 0; i < n; i++) {
      this.baseBand.setS(input[i]);
      const mixed = this.baseBand.mulCx(this.baseBandOscillator.rotate());
      const filtered = this.baseBandLowPass.push(mixed);
      const frequencyValue = this.frequencyModulation.demod(filtered);
      const syncPulseValue = this.syncPulseFilter.avg(frequencyValue);
      const syncPulseDelayedValue = this.syncPulseValueDelay.push(syncPulseValue);
      out[i] = frequencyValue;
      if (!this.syncPulseTrigger.latch(syncPulseValue)) {
        this.syncPulseCounter++;
      } else if (this.syncPulseCounter < this.syncPulse5msMinSamples
        || this.syncPulseCounter > this.syncPulse20msMaxSamples
        || Math.abs(syncPulseDelayedValue - this.syncPulseFrequencyValue) > this.syncPulseFrequencyTolerance) {
        this.syncPulseCounter = 0;
      } else {
        if (this.syncPulseCounter < this.syncPulse5msMaxSamples) {
          this.syncPulseWidth = SYNC_WIDTH_5MS;
        } else if (this.syncPulseCounter < this.syncPulse9msMaxSamples) {
          this.syncPulseWidth = SYNC_WIDTH_9MS;
        } else {
          this.syncPulseWidth = SYNC_WIDTH_20MS;
        }
        this.syncPulseOffset = i - this.syncPulseFilterDelay;
        this.frequencyOffset = syncPulseDelayedValue - this.syncPulseFrequencyValue;
        detected = true;
        this.syncPulseCounter = 0;
      }
    }
    return detected;
  }

  /** 交错样本 + 通道选择（0=按给定缓冲；1=左；2=右；3=左右均值）。解调结果就地写回。 */
  processInterleaved(buffer: Float32Array, channelSelect: number): boolean {
    let detected = false;
    const channels = channelSelect > 0 ? 2 : 1;
    const frames = Math.floor(buffer.length / channels);
    const out = new Float32Array(frames);
    for (let i = 0; i < frames; i++) {
      if (channelSelect === 1) {
        this.baseBand.setS(buffer[2 * i]);
      } else if (channelSelect === 2) {
        this.baseBand.setS(buffer[2 * i + 1]);
      } else if (channelSelect === 3) {
        this.baseBand.setS(0.5 * (buffer[2 * i] + buffer[2 * i + 1]));
      } else if (channelSelect === 4) {
        this.baseBand.setRI(buffer[2 * i], buffer[2 * i + 1]);
      } else {
        this.baseBand.setS(buffer[i]);
      }
      const mixed = this.baseBand.mulCx(this.baseBandOscillator.rotate());
      const filtered = this.baseBandLowPass.push(mixed);
      const frequencyValue = this.frequencyModulation.demod(filtered);
      const syncPulseValue = this.syncPulseFilter.avg(frequencyValue);
      const syncPulseDelayedValue = this.syncPulseValueDelay.push(syncPulseValue);
      out[i] = frequencyValue;
      if (!this.syncPulseTrigger.latch(syncPulseValue)) {
        this.syncPulseCounter++;
      } else if (this.syncPulseCounter < this.syncPulse5msMinSamples
        || this.syncPulseCounter > this.syncPulse20msMaxSamples
        || Math.abs(syncPulseDelayedValue - this.syncPulseFrequencyValue) > this.syncPulseFrequencyTolerance) {
        this.syncPulseCounter = 0;
      } else {
        if (this.syncPulseCounter < this.syncPulse5msMaxSamples) {
          this.syncPulseWidth = SYNC_WIDTH_5MS;
        } else if (this.syncPulseCounter < this.syncPulse9msMaxSamples) {
          this.syncPulseWidth = SYNC_WIDTH_9MS;
        } else {
          this.syncPulseWidth = SYNC_WIDTH_20MS;
        }
        this.syncPulseOffset = i - this.syncPulseFilterDelay;
        this.frequencyOffset = syncPulseDelayedValue - this.syncPulseFrequencyValue;
        detected = true;
        this.syncPulseCounter = 0;
      }
    }
    for (let i = 0; i < frames; i++) {
      buffer[i] = out[i];
    }
    return detected;
  }
}