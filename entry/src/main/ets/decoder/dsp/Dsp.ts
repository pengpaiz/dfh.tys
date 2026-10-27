/*
 * DSP primitives — ported from xdsopl/robot36 (Java) for HarmonyOS ArkTS.
 *
 * Original: Copyright 2024 Ahmet Inan <xdsopl@gmail.com>  (BSD 0-Clause)
 * This port keeps the algorithms/formulas identical; only naming was adapted to ArkTS
 * (no method overloading, no `any`, TypedArray storage).
 */

export class Cx {
  real: number = 0;
  imag: number = 0;

  setRI(real: number, imag: number): Cx {
    this.real = real;
    this.imag = imag;
    return this;
  }

  setS(real: number): Cx {
    this.real = real;
    this.imag = 0;
    return this;
  }

  copyFrom(other: Cx): Cx {
    this.real = other.real;
    this.imag = other.imag;
    return this;
  }

  norm(): number {
    return this.real * this.real + this.imag * this.imag;
  }

  abs(): number {
    return Math.sqrt(this.norm());
  }

  arg(): number {
    return Math.atan2(this.imag, this.real);
  }

  polar(a: number, b: number): Cx {
    this.real = a * Math.cos(b);
    this.imag = a * Math.sin(b);
    return this;
  }

  mulF(value: number): Cx {
    this.real *= value;
    this.imag *= value;
    return this;
  }

  mulCx(other: Cx): Cx {
    const tmp = this.real * other.real - this.imag * other.imag;
    this.imag = this.real * other.imag + this.imag * other.real;
    this.real = tmp;
    return this;
  }

  divF(value: number): Cx {
    this.real /= value;
    this.imag /= value;
    return this;
  }
}

/** Numerically controlled oscillator (unit-magnitude rotator). */
export class Phasor {
  private value: Cx = new Cx().setRI(1, 0);
  private delta: Cx;

  constructor(freq: number, rate: number) {
    const omega = 2 * Math.PI * freq / rate;
    this.delta = new Cx().setRI(Math.cos(omega), Math.sin(omega));
  }

  rotate(): Cx {
    return this.value.divF(this.value.mulCx(this.delta).abs());
  }
}

/** Sliding sum via a binary tree (O(log n) update). */
export class SimpleMovingSum {
  private tree: Float64Array;
  private leaf: number;
  readonly length: number;

  constructor(length: number) {
    this.length = length;
    this.tree = new Float64Array(2 * length);
    this.leaf = length;
  }

  add(input: number): void {
    this.tree[this.leaf] = input;
    let child = this.leaf;
    let parent = Math.floor(this.leaf / 2);
    while (parent > 0) {
      this.tree[parent] = this.tree[child] + this.tree[child ^ 1];
      child = parent;
      parent = Math.floor(parent / 2);
    }
    this.leaf++;
    if (this.leaf >= this.tree.length) {
      this.leaf = this.length;
    }
  }

  sum(): number {
    return this.tree[1];
  }
}

export class SimpleMovingAverage {
  private inner: SimpleMovingSum;
  readonly length: number;

  constructor(length: number) {
    this.length = length;
    this.inner = new SimpleMovingSum(length);
  }

  avg(input: number): number {
    this.inner.add(input);
    return this.inner.sum() / this.length;
  }
}

/** Digital delay line. */
export class Delay {
  readonly length: number;
  private buf: Float64Array;
  private pos: number = 0;

  constructor(length: number) {
    this.length = length;
    this.buf = new Float64Array(length);
  }

  push(input: number): number {
    const tmp = this.buf[this.pos];
    this.buf[this.pos] = input;
    this.pos++;
    if (this.pos >= this.length) {
      this.pos = 0;
    }
    return tmp;
  }
}

/** Complex FIR convolution (coefficients in `taps`). */
export class ComplexConvolution {
  readonly length: number;
  readonly taps: Float32Array;
  private real: Float32Array;
  private imag: Float32Array;
  private sum: Cx = new Cx();
  private pos: number = 0;

  constructor(length: number) {
    this.length = length;
    this.taps = new Float32Array(length);
    this.real = new Float32Array(length);
    this.imag = new Float32Array(length);
  }

  push(input: Cx): Cx {
    this.real[this.pos] = input.real;
    this.imag[this.pos] = input.imag;
    this.pos++;
    if (this.pos >= this.length) {
      this.pos = 0;
    }
    let re = 0;
    let im = 0;
    for (let k = 0; k < this.length; k++) {
      const tap = this.taps[k];
      re += tap * this.real[this.pos];
      im += tap * this.imag[this.pos];
      this.pos++;
      if (this.pos >= this.length) {
        this.pos = 0;
      }
    }
    return this.sum.setRI(re, im);
  }
}

/** FM demodulator: wraps per-sample phase difference scaled by rate/(bandwidth*pi). */
export class FrequencyModulation {
  private prev: number = 0;
  private scale: number;
  private Pi: number = Math.PI;
  private TwoPi: number = 2 * Math.PI;

  constructor(bandwidth: number, sampleRate: number) {
    this.scale = sampleRate / (bandwidth * Math.PI);
  }

  private wrap(value: number): number {
    if (value < -this.Pi) {
      return value + this.TwoPi;
    }
    if (value > this.Pi) {
      return value - this.TwoPi;
    }
    return value;
  }

  demod(input: Cx): number {
    const phase = input.arg();
    const delta = this.wrap(phase - this.prev);
    this.prev = phase;
    return this.scale * delta;
  }
}

export class SchmittTrigger {
  private low: number;
  private high: number;
  private previous: boolean = false;

  constructor(low: number, high: number) {
    this.low = low;
    this.high = high;
  }

  latch(input: number): boolean {
    if (this.previous) {
      if (input < this.low) {
        this.previous = false;
      }
    } else {
      if (input > this.high) {
        this.previous = true;
      }
    }
    return this.previous;
  }
}

/** Kaiser window (I0 via series, sum sorted for numerical stability). */
export class Kaiser {
  private summands: Float64Array = new Float64Array(35);

  private square(value: number): number {
    return value * value;
  }

  private i0(x: number): number {
    this.summands[0] = 1;
    let val = 1;
    for (let n = 1; n < this.summands.length; n++) {
      val *= x / (2 * n);
      this.summands[n] = this.square(val);
    }
    this.summands.sort();
    let sum = 0;
    for (let n = this.summands.length - 1; n >= 0; n--) {
      sum += this.summands[n];
    }
    return sum;
  }

  window(a: number, n: number, N: number): number {
    const arg = Math.PI * a * Math.sqrt(1 - this.square((2.0 * n) / (N - 1) - 1));
    return this.i0(arg) / this.i0(Math.PI * a);
  }
}

export class Filter {
  static sinc(x: number): number {
    if (x === 0) {
      return 1;
    }
    const y = x * Math.PI;
    return Math.sin(y) / y;
  }

  static lowPass(cutoff: number, rate: number, n: number, N: number): number {
    const f = 2 * cutoff / rate;
    const x = n - (N - 1) / 2.0;
    return f * Filter.sinc(f * x);
  }
}

export class ExponentialMovingAverage {
  private alphaValue: number = 1;
  private prev: number = 0;

  avg(input: number): number {
    this.prev = this.prev * (1 - this.alphaValue) + this.alphaValue * input;
    return this.prev;
  }

  setAlpha(alpha: number): void {
    this.alphaValue = alpha;
  }

  setAlphaOrder(alpha: number, order: number): void {
    this.alphaValue = Math.pow(alpha, 1.0 / order);
  }

  cutoff(freq: number, rate: number, order: number): void {
    const x = Math.cos(2 * Math.PI * freq / rate);
    this.setAlphaOrder(x - 1 + Math.sqrt(x * (x - 4) + 3), order);
  }

  reset(): void {
    this.prev = 0;
  }
}