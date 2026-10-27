/*
 * Look4Sat. Polar radar visualization, ported from the Android Compose RadarView.
 * The whole radar rotates by the device heading; the aim reticle sits at the top
 * (phone-forward direction) and moves radially with the device tilt.
 */

import { RadarTrackResult, RadarPoint, sph2CartDeg } from '../../domain/predict/RadarTrack';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RING_COUNT = 3;
const SWEEP_STEP_DEG = 1.5;
const TICK_MS = 33;
const PULSE_STEP = 0.033;
const TRACK_RED = '#E74C3C';
const AIM_COLOR = '#538EF4';
const LIVE_COLOR = '#F5C518';
const DIR_LABEL_DIST = 1.02;
const LABEL_COLOR = '#E67E22';

@Component
export struct RadarCanvas {
  @Prop azimuthDeg: number = 0;
  @Prop elevationDeg: number = 0;
  @Prop @Watch('onTrackChanged') track: RadarTrackResult = new RadarTrackResult([], [], []);
  @Prop trackColor: string = '#E67E22';
  @Prop eclipsed: boolean = false;
  @Prop headingAzDeg: number = 0;
  @Prop headingTiltDeg: number = 0;
  @Prop liveAzDeg: number = -999;
  @Prop liveElevDeg: number = -999;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private lastW: number = 0;
  private sweepDeg: number = 0;
  private pulse: number = 0;
  private timerId: number = -1;
  private warmupTimer1: number = -1;
  private warmupTimer2: number = -1;
  /** 已卸载标记：卸载后任何遗留回调都不再重绘 */
  private destroyed: boolean = false;

  // ---- 轨迹点缓存：track 未变化时复用（§9/§10，避免每帧重建数组与点对象）----
  private trackCacheValid: boolean = false;
  private cachedXsRef: number[] = [];
  private cachedYsRef: number[] = [];
  private cachedRadius: number = 0;
  private cachedPoints: RadarPoint[] = [];

  aboutToAppear(): void {
    this.timerId = setInterval((): void => {
      this.sweepDeg = (this.sweepDeg + SWEEP_STEP_DEG) % 360;
      const next = this.pulse + PULSE_STEP;
      this.pulse = next >= 1 ? 0 : next;
      this.redraw();
    }, TICK_MS);
    // 补偿 Sheet 动效/初次布局导致的漏帧（定时器句柄保存下来，卸载时清理）
    this.warmupTimer1 = setTimeout((): void => {
      this.redraw();
    }, 100);
    this.warmupTimer2 = setTimeout((): void => {
      this.redraw();
    }, 400);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.warmupTimer1 >= 0) {
      clearTimeout(this.warmupTimer1);
      this.warmupTimer1 = -1;
    }
    if (this.warmupTimer2 >= 0) {
      clearTimeout(this.warmupTimer2);
      this.warmupTimer2 = -1;
    }
  }

  /** 轨迹数据变化：作废点位缓存，下一帧重建一次。 */
  onTrackChanged(): void {
    this.trackCacheValid = false;
  }

  private redraw(): void {
    if (this.destroyed) {
      return;
    }
    if (this.lastW > 0) {
      this.drawCanvas(this.lastW, this.lastW);
    }
  }

  /** 带缓存的轨迹点构建：只有 track 引用或半径变化时才真正重建。 */
  private trackPoints(radius: number): RadarPoint[] {
    const xs = this.track.xs;
    const ys = this.track.ys;
    if (this.trackCacheValid && this.cachedXsRef === xs && this.cachedYsRef === ys
      && this.cachedRadius === radius) {
      return this.cachedPoints;
    }
    const pts = this.buildValidTrackPoints(xs, ys, radius);
    this.cachedXsRef = xs;
    this.cachedYsRef = ys;
    this.cachedRadius = radius;
    this.cachedPoints = pts;
    this.trackCacheValid = true;
    return pts;
  }

  private drawCanvas(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    try {
      this.renderCanvas(width, height);
    } catch (e) {
      hilog.error(0x0001, 'RadarCanvas', `draw fail: ${e}`);
    }
  }

  private renderCanvas(width: number, height: number): void {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, width, height);
    // 留出画布边缘的余量，否则 N/E/S/W 罗盘文字会被画布裁掉
    const radius = Math.min(width, height) / 2 * 0.85;

    ctx.save();
    ctx.translate(width / 2, height / 2);
    ctx.beginPath();
    ctx.arc(0, 0, radius * 1.06, 0, Math.PI * 2);
    ctx.clip();
    this.drawSweep(ctx, radius, this.sweepDeg);
    this.drawRings(ctx, radius);
    this.drawElevationLabels(ctx, radius);
    this.drawTrack(ctx, radius);
    this.drawSatellite(ctx, radius);
    this.drawLivePos(ctx, radius);
    this.drawAim(ctx, radius);
    ctx.restore();
    // 罗盘文字画在裁剪区域之外，避免被圆裁剪
    ctx.save();
    ctx.translate(width / 2, height / 2);
    this.drawCompassLabels(ctx, radius);
    ctx.restore();
  }

  private drawRings(ctx: CanvasRenderingContext2D, radius: number): void {
    ctx.strokeStyle = '#8F9BA8';
    ctx.lineWidth = 1.5;
    const step = radius / RING_COUNT;
    for (let i = 1; i <= RING_COUNT; i++) {
      ctx.beginPath();
      ctx.arc(0, 0, radius - step * (i - 1), 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.beginPath();
    ctx.moveTo(-radius, 0);
    ctx.lineTo(radius, 0);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(0, -radius);
    ctx.lineTo(0, radius);
    ctx.stroke();
  }

  private drawElevationLabels(ctx: CanvasRenderingContext2D, radius: number): void {
    const step = radius / RING_COUNT;
    ctx.fillStyle = LABEL_COLOR;
    ctx.font = '11vp sans-serif';
    ctx.textAlign = 'center';
    for (let i = 1; i < RING_COUNT; i++) {
      const ringRadius = radius - step * i;
      ctx.fillText(`${i * 30}°`, 0, -ringRadius - 6);
    }
    // 天顶标签偏离正中心，避免高仰角时被卫星/瞄准标记覆盖
    ctx.fillText('90°', -radius * 0.14, -radius * 0.08);
  }

  private drawCompassLabels(ctx: CanvasRenderingContext2D, radius: number): void {
    const r = radius * DIR_LABEL_DIST;
    ctx.fillStyle = LABEL_COLOR;
    ctx.font = '12vp sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('N', 0, -r);
    ctx.fillText('E', r, 0);
    ctx.fillText('S', 0, r);
    ctx.fillText('W', -r, 0);
    ctx.textBaseline = 'alphabetic';
  }

  private drawSweep(ctx: CanvasRenderingContext2D, radius: number, deg: number): void {
    const sweepWidth = 50;
    const a0 = (deg - sweepWidth) * Math.PI / 180 - Math.PI / 2;
    const a1 = deg * Math.PI / 180 - Math.PI / 2;
    ctx.save();
    ctx.fillStyle = this.trackColor;
    ctx.globalAlpha = 0.10;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.arc(0, 0, radius, a0, a1);
    ctx.closePath();
    ctx.fill();
    ctx.globalAlpha = 0.55;
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.arc(0, 0, radius, a0, a1);
    ctx.stroke();
    ctx.globalAlpha = 0.35;
    ctx.beginPath();
    ctx.arc(0, 0, radius * 0.65, a0, a1);
    ctx.stroke();
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  private drawTrack(ctx: CanvasRenderingContext2D, radius: number): void {
    const pts = this.trackPoints(radius);
    // 注意：这里不要打日志——drawTrack 每帧都会执行（§11 高频日志）
    if (pts.length <= 1) {
      return;
    }
    ctx.save();
    ctx.strokeStyle = TRACK_RED;
    ctx.lineWidth = 2.5;
    ctx.globalAlpha = 0.85;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 1; i < pts.length; i++) {
      ctx.lineTo(pts[i].x, pts[i].y);
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
    ctx.fillStyle = TRACK_RED;
    this.drawPathTriangle(ctx, pts, 1 / 3);
    this.drawPathTriangle(ctx, pts, 2 / 3);
    ctx.restore();
  }

  private buildValidTrackPoints(xs: number[], ys: number[], radius: number): Array<RadarPoint> {
    const arr: Array<RadarPoint> = [];
    for (let i = 0; i < xs.length; i++) {
      const px = xs[i] * radius;
      const py = ys[i] * radius;
      if (!isFinite(px) || !isFinite(py)) {
        continue;
      }
      const dist = Math.sqrt(px * px + py * py);
      if (dist > radius) {
        arr.push(new RadarPoint(px / dist * radius, py / dist * radius));
      } else {
        arr.push(new RadarPoint(px, py));
      }
    }
    return arr;
  }

  private drawPathTriangle(ctx: CanvasRenderingContext2D, pts: Array<RadarPoint>, fraction: number): void {
    const len = pts.length;
    if (len < 2) {
      return;
    }
    const pos = Math.min(len - 1, Math.floor(fraction * len));
    const prev = Math.max(0, pos - 1);
    const p0x = pts[prev].x;
    const p0y = pts[prev].y;
    const p1x = pts[pos].x;
    const p1y = pts[pos].y;
    const dx = p1x - p0x;
    const dy = p1y - p0y;
    const norm = Math.sqrt(dx * dx + dy * dy);
    if (norm < 1e-6) {
      return;
    }
    const ux = dx / norm;
    const uy = dy / norm;
    const bx = -uy;
    const by = ux;
    const size = 12;
    ctx.beginPath();
    ctx.moveTo(p1x + ux * size, p1y + uy * size);
    ctx.lineTo(p1x - ux * size * 0.5 + bx * size * 0.8, p1y - uy * size * 0.5 + by * size * 0.8);
    ctx.lineTo(p1x - ux * size * 0.5 - bx * size * 0.8, p1y - uy * size * 0.5 - by * size * 0.8);
    ctx.closePath();
    ctx.fill();
  }

  private drawSatellite(ctx: CanvasRenderingContext2D, radius: number): void {
    if (this.elevationDeg <= 0) {
      return;
    }
    const pt = sph2CartDeg(this.azimuthDeg, this.elevationDeg, radius);
    ctx.save();
    ctx.fillStyle = this.trackColor;
    ctx.beginPath();
    ctx.arc(pt.x, pt.y, 6, 0, Math.PI * 2);
    ctx.fill();
    if (!this.eclipsed) {
      const glowRadius = 10 + 16 * this.pulse;
      ctx.strokeStyle = this.trackColor;
      ctx.lineWidth = 2;
      ctx.globalAlpha = 0.6 * (1 - this.pulse);
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, glowRadius, 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  private drawLivePos(ctx: CanvasRenderingContext2D, radius: number): void {
    if (this.liveElevDeg <= 0 || this.liveAzDeg < -900) {
      return;
    }
    const pt = sph2CartDeg(this.liveAzDeg, this.liveElevDeg, radius);
    ctx.save();
    ctx.fillStyle = LIVE_COLOR;
    ctx.strokeStyle = LIVE_COLOR;
    ctx.lineWidth = 2.5;
    ctx.globalAlpha = 0.35;
    ctx.beginPath();
    ctx.arc(pt.x, pt.y, 12 + 6 * this.pulse, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 1;
    ctx.beginPath();
    ctx.arc(pt.x, pt.y, 6, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  private drawAim(ctx: CanvasRenderingContext2D, radius: number): void {
    const elevDeg = Math.max(0, Math.min(90, this.headingTiltDeg));
    const pt = sph2CartDeg(this.headingAzDeg, elevDeg, radius);
    const px = pt.x;
    const py = pt.y;
    const size = 18;
    ctx.save();
    ctx.strokeStyle = AIM_COLOR;
    ctx.fillStyle = AIM_COLOR;
    ctx.lineWidth = 2.5;
    ctx.globalAlpha = 0.12;
    ctx.beginPath();
    ctx.arc(px, py, 14, 0, Math.PI * 2);
    ctx.fill();
    ctx.globalAlpha = 0.95;
    ctx.beginPath();
    ctx.arc(px, py, 9, 0, Math.PI * 2);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(px - size, py);
    ctx.lineTo(px - 9, py);
    ctx.moveTo(px + 9, py);
    ctx.lineTo(px + size, py);
    ctx.moveTo(px, py - size);
    ctx.lineTo(px, py - 9);
    ctx.moveTo(px, py + 9);
    ctx.lineTo(px, py + size);
    ctx.stroke();
    ctx.globalAlpha = 0.95;
    ctx.beginPath();
    ctx.arc(px, py, 2.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    ctx.globalAlpha = 1;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .aspectRatio(1)
      .onReady(() => {
        const w = Number(this.ctx.width);
        const h = Number(this.ctx.height);
        if (w > 0 && h > 0) {
          this.lastW = w;
          this.drawCanvas(w, h);
        }
      })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        const w = Number(newValue.width);
        const h = Number(newValue.height);
        if (w > 0 && h > 0) {
          // 仅记录尺寸，绘制统一由 33ms 定时器完成，避免拖动中逐帧同步重绘
          this.lastW = w;
        }
      })
  }
}