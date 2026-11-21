import { AudioRecorder } from '../../common/AudioRecorder';

const BAND_COUNT = 16;
const FRAMES = 64;

/**
 * 录音频谱瀑布图：横轴=时间（旧→新，从左向右推进），纵轴=频带（低频在下），
 * 颜色深浅表示该频带能量。数据来自 AudioRecorder 的 Goertzel 频谱。
 */
@Component
export struct RecordWaterfall {
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private timerId: number = -1;
  private w: number = 0;
  private h: number = 0;
  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.timerId = setInterval((): void => {
      if (!this.destroyed) {
        this.draw();
      }
    }, 120);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private syncSize(): void {
    const w = Number(this.ctx.width);
    const h = Number(this.ctx.height);
    if (w > 0 && h > 0) {
      this.w = w;
      this.h = h;
    }
  }

  private draw(): void {
    if (this.w <= 0 || this.h <= 0) {
      return;
    }
    const ctx = this.ctx;
    // 深色底 + 白色细网格，贴近 SDR 频谱瀑布的观感
    ctx.fillStyle = '#05070C';
    ctx.fillRect(0, 0, this.w, this.h);
    const rowH = this.h / BAND_COUNT;
    ctx.fillStyle = 'rgba(255, 255, 255, 0.05)';
    for (let b = 0; b < BAND_COUNT; b++) {
      ctx.fillRect(0, b * rowH, this.w, 1);
    }
    const rows = AudioRecorder.getInstance().recentSpectrum();
    if (rows.length === 0) {
      return;
    }
    const colW = this.w / FRAMES;
    const startX = this.w - rows.length * colW;
    for (let c = 0; c < rows.length; c++) {
      const row = rows[c];
      const x = startX + c * colW;
      for (let b = 0; b < BAND_COUNT; b++) {
        const v = row[b];
        ctx.fillStyle = RecordWaterfall.colorFor(v);
        // 频带 0（低频）画在底部
        ctx.fillRect(x, (BAND_COUNT - 1 - b) * rowH, colW + 0.6, rowH + 0.6);
      }
    }
  }

  /** 0~1 能量 → 无线电瀑布常用色阶：黑→深蓝→青→绿→黄→橙→红→白 */
  private static colorFor(v: number): string {
    const stops: number[][] = [
      [5, 7, 12],
      [8, 24, 78],
      [0, 92, 170],
      [0, 172, 190],
      [40, 210, 120],
      [220, 220, 40],
      [255, 140, 20],
      [255, 56, 40],
      [255, 240, 220]
    ];
    const t = Math.max(0, Math.min(1, v)) * (stops.length - 1);
    const i = Math.min(stops.length - 2, Math.floor(t));
    const f = t - i;
    const a = stops[i];
    const b = stops[i + 1];
    const r = Math.round(a[0] + (b[0] - a[0]) * f);
    const g = Math.round(a[1] + (b[1] - a[1]) * f);
    const bl = Math.round(a[2] + (b[2] - a[2]) * f);
    return `rgb(${r}, ${g}, ${bl})`;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.syncSize();
        this.draw();
      })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        this.syncSize();
      })
  }
}
