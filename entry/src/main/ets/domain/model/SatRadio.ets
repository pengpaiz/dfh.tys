/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

export class SatRadio {
  uuid: string;
  info: string;
  isAlive: boolean;
  downlinkLow: number | null;
  downlinkHigh: number | null;
  downlinkMode: string | null;
  uplinkLow: number | null;
  uplinkHigh: number | null;
  uplinkMode: string | null;
  isInverted: boolean;
  catnum: number | null;

  constructor(uuid: string, info: string = '', isAlive: boolean = true, downlinkLow: number | null = null,
              downlinkHigh: number | null = null, downlinkMode: string | null = null, uplinkLow: number | null = null,
              uplinkHigh: number | null = null, uplinkMode: string | null = null, isInverted: boolean = false,
              catnum: number | null = null) {
    this.uuid = uuid;
    this.info = info;
    this.isAlive = isAlive;
    this.downlinkLow = downlinkLow;
    this.downlinkHigh = downlinkHigh;
    this.downlinkMode = downlinkMode;
    this.uplinkLow = uplinkLow;
    this.uplinkHigh = uplinkHigh;
    this.uplinkMode = uplinkMode;
    this.isInverted = isInverted;
    this.catnum = catnum;
  }
}