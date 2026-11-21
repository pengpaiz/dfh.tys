/*
 * 像素缓冲 —— 等价于 xdsopl/robot36 的 PixelBuffer（BSD 0-Clause, Copyright 2024 Ahmet Inan）。
 * pixels 存 ARGB Int32；line 为“已写入行数”游标（-1 表示尚未锁定图像）。
 */

export class PixelBuffer {
  pixels: Int32Array;
  width: number;
  height: number;
  line: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.line = 0;
    this.pixels = new Int32Array(width * height);
  }

  /** 复用同一实例、改尺寸（避免解码期分配） */
  resize(width: number, height: number): void {
    if (this.width !== width || this.height !== height) {
      this.width = width;
      this.height = height;
      this.pixels = new Int32Array(width * height);
    }
  }

  fill(color: number): void {
    this.pixels.fill(color);
  }
}