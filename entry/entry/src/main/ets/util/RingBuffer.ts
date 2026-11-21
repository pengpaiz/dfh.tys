/*
 * 解调后样本的环形缓冲（保留 ≥2s，建议 7s）。
 * 用掩码回绕；提供“从回退点开始顺序取”的迭代器语义，避免热路径分配。
 */

export class RingBuffer {
  readonly capacity: number;
  private mask: number;
  private buf: Float32Array;
  private writePos: number = 0;
  private size: number = 0;

  constructor(capacityPow2: number) {
    // capacity 必须是 2 的幂
    let cap = 1;
    while (cap < capacityPow2) {
      cap <<= 1;
    }
    this.capacity = cap;
    this.mask = cap - 1;
    this.buf = new Float32Array(cap);
  }

  get count(): number {
    return this.size;
  }

  clear(): void {
    this.writePos = 0;
    this.size = 0;
  }

  /** 压入一段样本；超出容量时丢弃最旧数据。 */
  write(src: Float32Array, n: number): void {
    for (let i = 0; i < n; i++) {
      this.buf[this.writePos] = src[i];
      this.writePos = (this.writePos + 1) & this.mask;
      if (this.size < this.capacity) {
        this.size++;
      }
    }
  }

  /**
   * 读取“最旧的第 offset 个”样本（offset=0 即最旧）。
   * 返回 NaN 表示越界。
   */
  read(offset: number): number {
    if (offset < 0 || offset >= this.size) {
      return Number.NaN;
    }
    const start = (this.writePos - this.size + this.capacity) & this.mask;
    return this.buf[(start + offset) & this.mask];
  }

  /** 把最旧的 offset 起 count 个样本拷到 dst；返回实际拷贝数。 */
  copyTo(dst: Float32Array, offset: number, count: number): number {
    if (offset < 0 || offset >= this.size) {
      return 0;
    }
    const start = (this.writePos - this.size + this.capacity) & this.mask;
    const n = Math.min(count, this.size - offset);
    for (let i = 0; i < n; i++) {
      dst[i] = this.buf[(start + offset + i) & this.mask];
    }
    return n;
  }
}