/*
 * Look4Sat. Device heading helper ported from Android SensorsRepo:
 * subscribes ROTATION_VECTOR, converts quaternion to orientation
 * (azimuth/pitch) synchronously, and applies low-pass smoothing with
 * 0/360 wraparound handling. Falls back to the ORIENTATION sensor when
 * rotation-vector data never arrives (some devices).
 */

import { sensor } from '@kit.SensorServiceKit';

const SMOOTHING_FACTOR = 0.15;
const INTERVAL_NS = 50000000;
const FULL_CIRCLE = 360;
const RAD2DEG = 180 / Math.PI;
const FALLBACK_MS = 1000;
const FALLBACK_CHECK_MS = 250;

export class DeviceOrientation {
  private listener: (azimuth: number, pitch: number) => void = (az: number, pt: number): void => {
  };
  private smoothAzimuth: number = 0;
  private smoothPitch: number = 0;
  private hasInit: boolean = false;
  private started: boolean = false;
  private sawEvent: boolean = false;
  private fallbackUsed: boolean = false;
  private checkTimer: number = -1;
  private startTime: number = 0;

  start(listener: (azimuth: number, pitch: number) => void): void {
    this.listener = listener;
    this.smoothAzimuth = 0;
    this.smoothPitch = 0;
    this.hasInit = false;
    this.sawEvent = false;
    this.fallbackUsed = false;
    if (this.started) {
      return;
    }
    this.started = true;
    this.startTime = Date.now();
    try {
      sensor.on(sensor.SensorId.ROTATION_VECTOR,
        (data: sensor.RotationVectorResponse): void => {
          this.onRotationVector(data);
        }, { interval: INTERVAL_NS });
    } catch (e) {
      this.useFallback();
    }
    this.checkTimer = setInterval((): void => {
      if (this.sawEvent) {
        clearInterval(this.checkTimer);
        this.checkTimer = -1;
      } else if (!this.fallbackUsed && Date.now() - this.startTime > FALLBACK_MS) {
        this.useFallback();
      }
    }, FALLBACK_CHECK_MS);
  }

  stop(): void {
    if (this.checkTimer >= 0) {
      clearInterval(this.checkTimer);
      this.checkTimer = -1;
    }
    if (!this.started) {
      return;
    }
    this.started = false;
    try {
      sensor.off(sensor.SensorId.ROTATION_VECTOR);
    } catch (e) {
    }
    if (this.fallbackUsed) {
      try {
        sensor.off(sensor.SensorId.ORIENTATION);
      } catch (e) {
      }
    }
  }

  private useFallback(): void {
    if (this.fallbackUsed) {
      return;
    }
    this.fallbackUsed = true;
    try {
      sensor.on(sensor.SensorId.ORIENTATION,
        (data: sensor.OrientationResponse): void => {
          this.onOrientation(data);
        }, { interval: INTERVAL_NS });
    } catch (e) {
    }
  }

  private onOrientation(data: sensor.OrientationResponse): void {
    this.sawEvent = true;
    if (this.fallbackUsed) {
      this.processAngles(data.alpha, data.beta);
    }
  }

  private onRotationVector(data: sensor.RotationVectorResponse): void {
    this.sawEvent = true;
    if (this.fallbackUsed) {
      return;
    }
    const x = data.x;
    const y = data.y;
    const z = data.z;
    const w = data.w;
    // 手机顶边(Y轴)在世界坐标系的方向，作为“外包/顶边指向”：方位角+仰角
    const topX = 2 * (x * y - w * z);
    const topY = 1 - 2 * (x * x + z * z);
    const topZ = 2 * (y * z + w * x);
    const azimuth = Math.atan2(topX, topY) * RAD2DEG;
    const elevation = Math.asin(Math.max(-1, Math.min(1, topZ))) * RAD2DEG;
    this.processAngles(azimuth, elevation);
  }

  private processAngles(azimuthDeg: number, pitchDeg: number): void {
    const azimuth = (azimuthDeg + FULL_CIRCLE) % FULL_CIRCLE;
    const pitch = pitchDeg;
    if (!this.hasInit) {
      this.smoothAzimuth = azimuth;
      this.smoothPitch = pitch;
      this.hasInit = true;
    } else {
      this.smoothAzimuth = this.lowPassAngle(this.smoothAzimuth, azimuth);
      this.smoothPitch = this.lowPass(this.smoothPitch, pitch);
    }
    this.listener(Math.round(this.smoothAzimuth * 10) / 10, Math.round(this.smoothPitch * 10) / 10);
  }

  private lowPass(previous: number, current: number): number {
    return previous + SMOOTHING_FACTOR * (current - previous);
  }

  private lowPassAngle(previous: number, current: number): number {
    let delta = current - previous;
    while (delta > 180) {
      delta -= FULL_CIRCLE;
    }
    while (delta <= -180) {
      delta += FULL_CIRCLE;
    }
    return (previous + SMOOTHING_FACTOR * delta + FULL_CIRCLE) % FULL_CIRCLE;
  }
}