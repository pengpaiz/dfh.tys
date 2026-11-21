/*
 * YUV/RGB 转换 —— 移植自 xdsopl/robot36 的 ColorConverter（BSD 0-Clause, Copyright 2024 Ahmet Inan）。
 * BT.601 studio swing：Y-16、UV-128，系数 298/409/100/208/516，结果 clamp 0–255。
 */

export const YUV2RGB_PACK = 1;

function clampInt(value: number): number {
  return value < 0 ? 0 : (value > 255 ? 255 : value);
}

function clamp01(value: number): number {
  return value < 0 ? 0 : (value > 1 ? 1 : value);
}

function float2int(level: number): number {
  return clampInt(Math.round(255 * level));
}

function compress(level: number): number {
  return float2int(Math.sqrt(clamp01(level)));
}

/** 打包为 ARGB */
export function GRAY(level: number): number {
  return (0xff000000 | (0x00010101 * compress(level))) | 0;
}

export function RGB(red: number, green: number, blue: number): number {
  return (0xff000000 | (float2int(red) << 16) | (float2int(green) << 8) | float2int(blue)) | 0;
}

export function YUV2RGB(Y: number, U: number, V: number): number {
  // 入参已是 0–255 码值（打包在 R/G/B 通道里），**不能再乘 255**
  const y = clampInt(Y) - 16;
  const u = clampInt(U) - 128;
  const v = clampInt(V) - 128;
  const r = clampInt((298 * y + 409 * v + 128) >> 8);
  const g = clampInt((298 * y - 100 * u - 208 * v + 128) >> 8);
  const b = clampInt((298 * y + 516 * u + 128) >> 8);
  return (0xff000000 | (r << 16) | (g << 8) | b) | 0;
}

/** 从打包的 (Y,U,V) 解析为 ARGB */
export function YUV2RGB_PACKED(yuv: number): number {
  return YUV2RGB((yuv & 0x00ff0000) >> 16, (yuv & 0x0000ff00) >> 8, yuv & 0x000000ff);
}