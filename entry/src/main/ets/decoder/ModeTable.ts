/*
 * SSTV 模式表（v1 仅 Robot 36；预留扩展位）。
 * 时间表取自 xdsopl/robot36 的 Robot_36_Color（BSD 0-Clause, Copyright 2024 Ahmet Inan）。
 */

import { SYNC_WIDTH_9MS } from './Demodulator';

export interface SstvModeInfo {
  name: string;
  visCode: number;
  width: number;
  height: number;
  /** 行结构（秒） */
  syncPulseSeconds: number;
  syncPorchSeconds: number;
  luminanceSeconds: number;
  separatorSeconds: number;
  porchSeconds: number;
  chrominanceSeconds: number;
  /** 该模式同步脉冲所属宽度分组（5/9/20ms） */
  syncGroup: number;
}

export const ROBOT36: SstvModeInfo = {
  name: 'Robot 36',
  visCode: 8,
  width: 320,
  height: 240,
  syncPulseSeconds: 0.009,
  syncPorchSeconds: 0.003,
  luminanceSeconds: 0.088,
  separatorSeconds: 0.0045,
  porchSeconds: 0.0015,
  chrominanceSeconds: 0.044,
  syncGroup: SYNC_WIDTH_9MS
};

/** 扩展位：后续可在此追加 Robot 72 / Scottie / Martin 等 */
export const MODE_TABLE: SstvModeInfo[] = [ROBOT36];

export function findModeByVis(code: number): SstvModeInfo | null {
  for (let i = 0; i < MODE_TABLE.length; i++) {
    if (MODE_TABLE[i].visCode === code) {
      return MODE_TABLE[i];
    }
  }
  return null;
}

/** 行采样数 = 同步+肩+Y+分隔+肩+C（按给定采样率） */
export function scanLineSamples(mode: SstvModeInfo, sampleRate: number): number {
  const seconds = mode.syncPulseSeconds + mode.syncPorchSeconds + mode.luminanceSeconds
    + mode.separatorSeconds + mode.porchSeconds + mode.chrominanceSeconds;
  return Math.round(seconds * sampleRate);
}

/** 第一行“第一个像素样本”相对行同步起点的偏移（= 同步肩时长） */
export function firstPixelSamples(mode: SstvModeInfo, sampleRate: number): number {
  return Math.round(mode.syncPorchSeconds * sampleRate);
}