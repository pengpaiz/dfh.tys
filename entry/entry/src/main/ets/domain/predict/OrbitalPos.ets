/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { SPEED_OF_LIGHT } from './Constants';

const GM_EARTH = 3.986004418E14;
const EARTH_RADIUS_M = 6.37E6;

export class SatOrbitalPos {
  azimuth: number;
  elevation: number;
  latitude: number;
  longitude: number;
  altitude: number;
  distance: number;
  distanceRate: number;
  theta: number;
  time: number;
  phase: number;
  eclipseDepth: number;
  eclipsed: boolean;
  aboveHorizon: boolean;

  constructor() {
    this.azimuth = 0.0;
    this.elevation = 0.0;
    this.latitude = 0.0;
    this.longitude = 0.0;
    this.altitude = 0.0;
    this.distance = 0.0;
    this.distanceRate = 0.0;
    this.theta = 0.0;
    this.time = 0;
    this.phase = 0.0;
    this.eclipseDepth = 0.0;
    this.eclipsed = false;
    this.aboveHorizon = false;
  }

  getDownlinkFreq(freq: number): number {
    return Math.trunc(freq * (SPEED_OF_LIGHT - this.distanceRate * 1000.0) / SPEED_OF_LIGHT);
  }

  getUplinkFreq(freq: number): number {
    return Math.trunc(freq * (SPEED_OF_LIGHT + this.distanceRate * 1000.0) / SPEED_OF_LIGHT);
  }

  getOrbitalVelocity(): number {
    const radius = EARTH_RADIUS_M + this.altitude * 1000.0;
    return Math.sqrt(GM_EARTH / radius) / 1000.0;
  }
}