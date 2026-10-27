/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

export class SatGeoPos {
  latitude: number;
  longitude: number;
  altitude: number;
  qthLocator: string;
  timestamp: number;

  constructor(latitude: number, longitude: number, altitude: number = 0.0, qthLocator: string = 'null', timestamp: number = 0) {
    this.latitude = latitude;
    this.longitude = longitude;
    this.altitude = altitude;
    this.qthLocator = qthLocator;
    this.timestamp = timestamp;
  }
}