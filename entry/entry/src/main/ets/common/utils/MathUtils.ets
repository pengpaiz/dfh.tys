/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { DEG2RAD, RAD2DEG, SEC_PER_DAY, EARTH_ROT_PER_SID_DAY, TWO_PI } from '../../domain/predict/Constants';

export function toRadians(value: number): number {
  return value * DEG2RAD;
}

export function toDegrees(value: number): number {
  return value * RAD2DEG;
}

export function roundFloat(value: number, decimals: number): number {
  let multiplier = 1;
  for (let i = 0; i < decimals; i++) {
    multiplier *= 10;
  }
  return Math.round(value * multiplier) / multiplier;
}

export function roundDouble(value: number, decimals: number): number {
  let multiplier = 1;
  for (let i = 0; i < decimals; i++) {
    multiplier *= 10;
  }
  return Math.round(value * multiplier) / multiplier;
}

/** Fractional part of [arg]. */
export function fraction(arg: number): number {
  return arg - Math.floor(arg);
}

/** Modulo: returns [arg1] mod [arg2], result always in [0, arg2). */
export function modulus(arg1: number, arg2: number): number {
  let r = arg1;
  const i = Math.floor(r / arg2);
  r -= i * arg2;
  if (r < 0.0) {
    r += arg2;
  }
  return r;
}

/** Reduce [value] to [0, 2π). */
export function mod2PI(value: number): number {
  let r = value;
  const i = Math.floor(r / TWO_PI);
  r -= i * TWO_PI;
  if (r < 0.0) {
    r += TWO_PI;
  }
  return r;
}

/** Reduce [x] to [0, 360). */
export function mod360(x: number): number {
  let r = x;
  const i = Math.floor(r / 360.0);
  r -= i * 360.0;
  if (r < 0.0) {
    r += 360.0;
  }
  return r;
}

/** Greenwich Mean Sidereal Time from Julian Date, in radians [0, 2π). */
export function thetaGJD(jd: number): number {
  const ut = fraction(jd + 0.5);
  const aJD = jd - ut;
  const tu = (aJD - 2451545.0) / 36525.0;
  let gmst = 24110.54841 + tu * (8640184.812866 + tu * (0.093104 - tu * 6.2E-6));
  gmst = modulus(gmst + SEC_PER_DAY * EARTH_ROT_PER_SID_DAY * ut, SEC_PER_DAY);
  return TWO_PI * gmst / SEC_PER_DAY;
}

/** Delta-ET: difference between UT and Ephemeris Time (seconds), PREDICT v2.2.5. */
export function deltaET(year: number): number {
  return 26.465 + 0.747622 * (year - 1950) + 1.886913 * Math.sin(TWO_PI * (year - 1975) / 33);
}

/** Convert Unix epoch milliseconds to daynum (days since 31 Dec 1979 00:00:00 UTC). */
export function millisToDaynum(timeMillis: number): number {
  return (timeMillis - 315446400000) / 86400000.0;
}

/** Convert daynum back to Unix epoch milliseconds. */
export function daynumToMillis(daynum: number): number {
  return Math.round((daynum + 3651.0) * 86400000.0);
}