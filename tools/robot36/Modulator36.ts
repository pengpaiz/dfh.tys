/*
 * Robot 36 调制器（仅测试代码）：把 Y/U/V 码值调制成 48k 单声道音频。
 * 与解码器约定一致：1500Hz=0、2300Hz=255（level = code/255）。
 * 偶行发 Y + V；奇行发 Y + U；V/U 恒定则两行共享同一色度对。
 */
import { synthVis } from './Synth';

export interface TestImage {
  width: number;
  height: number;
  /** 每像素的 studio-swing 码值：Y(16–235)、U/V(0–255) */
  y: Float32Array;
  u: Float32Array;
  v: Float32Array;
}

/** 生成 Robot36 音频：前置静音 + VIS 8 + 240 行（逐样本频率合成，段边界精确无漂移） */
export function modulateRobot36(img: TestImage, rate: number, leadingSilenceSec: number = 0.2): Float32Array {
  const lineSec = 0.009 + 0.003 + 0.088 + 0.0045 + 0.0015 + 0.044;
  const lineSamples = Math.round(lineSec * rate);
  const yEnd = 0.009 + 0.003 + 0.088;         // 100 ms
  const sepEnd = yEnd + 0.0045;               // 104.5 ms
  const chromaBegin = sepEnd + 0.0015;        // 106 ms
  const totalSec = leadingSilenceSec + 0.91 + lineSec * img.height + 0.2;
  const out = new Float32Array(Math.round(totalSec * rate));
  const phase = { p: 0 };

  const tone = (startSample: number, seconds: number, freq: number): number => {
    const n = Math.round(seconds * rate);
    for (let i = 0; i < n; i++) {
      if (startSample + i < out.length) {
        out[startSample + i] = 0.8 * Math.sin(phase.p);
      }
      phase.p += 2 * Math.PI * freq / rate;
    }
    return startSample + n;
  };
  const codeToHz = (code: number): number => {
    const level = Math.max(0, Math.min(255, code)) / 255;
    return 1500 + 800 * level;
  };

  let pos = Math.round(leadingSilenceSec * rate);
  pos = Math.round(synthVis(out, pos, 8, rate, 0, phase));

  for (let line = 0; line < img.height; line++) {
    const even = line % 2 === 0;
    const sepHz = even ? 1500 : 2300;
    const rowBase = pos;
    for (let s = 0; s < lineSamples; s++) {
      const idx = rowBase + s;
      if (idx >= out.length) {
        break;
      }
      const t = s / rate;
      let hz: number;
      if (t < 0.009) {
        hz = 1200;
      } else if (t < 0.012) {
        hz = 1500;
      } else if (t < yEnd) {
        const x = Math.min(img.width - 1, Math.floor(((t - 0.012) / 0.088) * img.width));
        hz = codeToHz(img.y[line * img.width + x]);
      } else if (t < sepEnd) {
        hz = sepHz;
      } else if (t < chromaBegin) {
        hz = 1500;
      } else {
        const x = Math.min(img.width - 1, Math.floor(((t - chromaBegin) / 0.044) * img.width));
        const i = line * img.width + x;
        hz = codeToHz(even ? img.v[i] : img.u[i]);
      }
      out[idx] = 0.8 * Math.sin(phase.p);
      phase.p += 2 * Math.PI * hz / rate;
    }
    pos = rowBase + lineSamples;
  }
  return out;
}

/** 依据码值生成期望 RGB（与解码器的配对规则一致） */
export function expectedRgb(img: TestImage, line: number, x: number): number[] {
  const i = line * img.width + x;
  const even = line % 2 === 0;
  const pairV = img.v[(even ? line : line - 1) * img.width + x];
  const pairU = img.u[(even ? line + 1 : line) * img.width + x];
  return [img.y[i], pairU, pairV];
}