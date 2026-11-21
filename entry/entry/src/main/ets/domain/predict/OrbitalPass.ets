/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { SatOrbitalObject } from './OrbitalObject';

export class SatOrbitalPass {
  aosTime: number;
  aosAzimuth: number;
  losTime: number;
  losAzimuth: number;
  altitude: number;
  maxElevation: number;
  orbitalObject: SatOrbitalObject | null;
  progress: number;
  hasDecayed: boolean;

  constructor(aosTime: number = 0, aosAzimuth: number = 90.0, losTime: number = 0, losAzimuth: number = 270.0,
              altitude: number = 1000, maxElevation: number = 75.0, orbitalObject: SatOrbitalObject | null = null,
              progress: number = 0.0, hasDecayed: boolean = false) {
    this.aosTime = aosTime;
    this.aosAzimuth = aosAzimuth;
    this.losTime = losTime;
    this.losAzimuth = losAzimuth;
    this.altitude = altitude;
    this.maxElevation = maxElevation;
    this.orbitalObject = orbitalObject;
    this.progress = progress;
    this.hasDecayed = hasDecayed;
  }

  get catNum(): number {
    return this.orbitalObject === null ? 0 : this.orbitalObject.data.catnum;
  }

  get name(): string {
    const data = this.orbitalObject === null ? null : this.orbitalObject.data;
    if (data === null) {
      return '';
    }
    return this.hasDecayed ? `${data.name} (decayed?)` : data.name;
  }

  get isDeepSpace(): boolean {
    return this.orbitalObject === null ? false : this.orbitalObject.data.isDeepSpace;
  }
}