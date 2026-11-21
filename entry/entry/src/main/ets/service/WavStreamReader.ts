/*
 * WAV 读取（纯解析，Node 可测）—— 移植自 xdsopl/robot36 的 WavFileReader 校验逻辑（BSD 0-Clause）。
 * 支持：RIFF/WAVE、PCM 8/16/24/32-bit、IEEE float 32/64-bit、mono/stereo、8–192 kHz、
 *       WAVE_FORMAT_EXTENSIBLE、奇数长度 chunk、data 前置/缺失、截断（允许 1 帧误差）。
 * 说明：真机的“流式分块读取”由 service/FileIoSource 负责，这里只解析给定字节与取帧。
 */

export const ENC_PCM = 1;
export const ENC_FLOAT = 3;

export interface WavHeader {
  encoding: number;
  channels: number;
  sampleRate: number;
  bits: number;
  blockAlign: number;
  dataOffset: number;
  dataLength: number;
  frameCount: number;
}

function u16(b: Uint8Array, p: number): number {
  return b[p] | (b[p + 1] << 8);
}

function u32(b: Uint8Array, p: number): number {
  return (u16(b, p) | (u16(b, p + 2) << 16)) >>> 0;
}

function id(b: Uint8Array, p: number, s: string): boolean {
  for (let i = 0; i < 4; i++) {
    if (b[p + i] !== s.charCodeAt(i)) {
      return false;
    }
  }
  return true;
}

/** 解析 WAV 头；不符合规范抛错（调用方可 catch 后提示用户）。 */
export function parseWavHeader(bytes: Uint8Array): WavHeader {
  if (bytes.length < 12) {
    throw new Error('文件太小，不是有效的 WAV');
  }
  if (!id(bytes, 0, 'RIFF') || !id(bytes, 8, 'WAVE')) {
    throw new Error('不是 RIFF/WAVE 文件');
  }
  let remaining = u32(bytes, 4) - 4;
  let off = 12;
  let encoding = 0;
  let channels = 0;
  let rate = 0;
  let blockAlign = 0;
  let byteRate = 0;
  let bits = 0;
  let formatFound = false;
  let dataOffset = -1;
  let dataLength = 0;

  while (remaining >= 8 && off + 8 <= bytes.length) {
    const chunkId = id(bytes, off, 'fmt ') ? 'fmt ' : (id(bytes, off, 'data') ? 'data' : '');
    const size = u32(bytes, off + 4);
    const body = off + 8;
    if (chunkId === 'data') {
      if (!formatFound) {
        throw new Error('WAV data 出现在 fmt 之前');
      }
      dataOffset = body;
      // 允许“声明长度 > 实际字节”与奇数长度的最后一个字节缺失（截断容错）
      dataLength = Math.min(size, Math.max(0, bytes.length - body));
      break;
    }
    const padded = size + (size & 1);
    if (padded > remaining || off + 8 + padded > bytes.length) {
      throw new Error('WAV chunk 超出 RIFF 大小（文件可能被截断）');
    }
    if (chunkId === 'fmt ') {
      if (formatFound || size < 16) {
        throw new Error('WAV fmt 块无效');
      }
      const fmtLen = Math.min(size, 40);
      const fmt = bytes.subarray(body, body + fmtLen);
      encoding = u16(fmt, 0);
      channels = u16(fmt, 2);
      rate = u32(fmt, 4);
      byteRate = u32(fmt, 8);
      blockAlign = u16(fmt, 12);
      bits = u16(fmt, 14);
      if (encoding === 0xfffe) {
        if (size < 40 || u16(fmt, 16) < 22 || 18 + u16(fmt, 16) > size) {
          throw new Error('WAVE_FORMAT_EXTENSIBLE 头无效');
        }
        const subFormat = u32(fmt, 24);
        const guidTail = [0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71];
        for (let i = 0; i < guidTail.length; i++) {
          if (fmt[28 + i] !== guidTail[i]) {
            throw new Error('不支持的 WAV subformat');
          }
        }
        if (subFormat !== ENC_PCM && subFormat !== ENC_FLOAT) {
          throw new Error('不支持的 WAV subformat（仅 PCM / IEEE float）');
        }
        encoding = subFormat;
        const validBits = u16(fmt, 18);
        if (validBits < 1 || validBits > bits || (encoding === ENC_FLOAT && validBits !== bits)) {
          throw new Error('WAV valid-bits 无效');
        }
        const mask = u32(fmt, 20);
        const popcount = (v: number): number => {
          let n = 0;
          let x = v;
          while (x > 0) {
            n += x & 1;
            x >>= 1;
          }
          return n;
        };
        if (mask !== 0 && ((channels === 1 && popcount(mask) !== 1) || (channels === 2 && mask !== 3))) {
          throw new Error('不支持的 WAV 声道布局');
        }
      }
      formatFound = true;
    }
    remaining -= 8 + padded;
    off = body + padded;
  }
  if (!formatFound) {
    throw new Error('缺少 WAV fmt 块');
  }
  if (dataOffset < 0) {
    throw new Error('缺少 WAV data 块');
  }
  if (channels !== 1 && channels !== 2) {
    throw new Error('WAV 必须是单声道或双声道');
  }
  if (rate < 8000 || rate > 192000) {
    throw new Error('WAV 采样率需在 8–192 kHz');
  }
  const width = bits / 8;
  const integral = encoding === ENC_PCM && (bits === 8 || bits === 16 || bits === 24 || bits === 32);
  const floating = encoding === ENC_FLOAT && (bits === 32 || bits === 64);
  if (!integral && !floating) {
    throw new Error('不支持的 WAV 编码或位深');
  }
  if (blockAlign !== channels * width || byteRate !== rate * blockAlign) {
    throw new Error('WAV 帧大小或字节率不一致');
  }
  if (dataOffset + dataLength > bytes.length) {
    // 截断：尽力读到文件末尾
    dataLength = bytes.length - dataOffset;
  }
  if (dataLength % blockAlign !== 0) {
    dataLength -= dataLength % blockAlign;
  }
  return {
    encoding,
    channels,
    sampleRate: rate,
    bits,
    blockAlign,
    dataOffset,
    dataLength,
    frameCount: Math.floor(dataLength / blockAlign)
  };
}

/** 取帧（frameCount 个），按 channelSelect 混为单声道（0/1/2/3 与参考实现一致）。 */
export function readFrames(bytes: Uint8Array, h: WavHeader, startFrame: number, frameCount: number, channelSelect: number = 0): Float32Array {
  const width = h.bits / 8;
  let start = startFrame;
  if (start < 0) {
    start = 0;
  }
  if (start > h.frameCount) {
    start = h.frameCount;
  }
  let n = frameCount;
  if (start + n > h.frameCount) {
    n = h.frameCount - start;
  }
  const out = new Float32Array(Math.max(0, n));
  for (let i = 0; i < n; i++) {
    const base = h.dataOffset + (start + i) * h.blockAlign;
    const ch0 = sampleAt(bytes, base, h);
    if (h.channels === 1) {
      out[i] = ch0;
    } else {
      const ch1 = sampleAt(bytes, base + width, h);
      if (channelSelect === 1) {
        out[i] = ch0;
      } else if (channelSelect === 2) {
        out[i] = ch1;
      } else {
        out[i] = 0.5 * (ch0 + ch1);
      }
    }
  }
  return out;
}

function sampleAt(bytes: Uint8Array, p: number, h: WavHeader): number {
  if (h.encoding === ENC_FLOAT) {
    if (h.bits === 32) {
      const dv = new DataView(bytes.buffer, bytes.byteOffset + p, 4);
      return dv.getFloat32(0, true);
    }
    const dv64 = new DataView(bytes.buffer, bytes.byteOffset + p, 8);
    return dv64.getFloat64(0, true);
  }
  if (h.bits === 8) {
    return ((bytes[p] & 255) - 128) / 128.0;
  }
  if (h.bits === 16) {
    const v = u16(bytes, p);
    return ((v << 16) >> 16) / 32768.0;
  }
  if (h.bits === 24) {
    let v = (bytes[p] & 255) | ((bytes[p + 1] & 255) << 8) | (bytes[p + 2] << 16);
    if (v & 0x800000) {
      v -= 0x1000000;
    }
    return v / 8388608.0;
  }
  const v32 = u32(bytes, p);
  return (v32 | 0) / 2147483648.0;
}