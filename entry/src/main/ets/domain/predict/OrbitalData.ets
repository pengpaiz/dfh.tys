/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import { DEG2RAD, MIN_PER_DAY, TWO_PI } from './Constants';
import { SatCelestialComputer } from './CelestialComputer';

export class SatOrbitalData {
  name: string;
  epoch: number;
  meanmo: number;
  eccn: number;
  incl: number;
  raan: number;
  argper: number;
  meanan: number;
  catnum: number;
  bstar: number;
  ndot: number;

  constructor(name: string, epoch: number, meanmo: number, eccn: number, incl: number, raan: number,
              argper: number, meanan: number, catnum: number, bstar: number, ndot: number = 0.0) {
    this.name = name;
    this.epoch = epoch;
    this.meanmo = meanmo;
    this.eccn = eccn;
    this.incl = incl;
    this.raan = raan;
    this.argper = argper;
    this.meanan = meanan;
    this.catnum = catnum;
    this.bstar = bstar;
    this.ndot = ndot;
  }

  get xincl(): number {
    return this.incl * DEG2RAD;
  }

  get xnodeo(): number {
    return this.raan * DEG2RAD;
  }

  get omegao(): number {
    return this.argper * DEG2RAD;
  }

  get xmo(): number {
    return this.meanan * DEG2RAD;
  }

  get xno(): number {
    return this.meanmo * TWO_PI / MIN_PER_DAY;
  }

  get orbitalPeriod(): number {
    return MIN_PER_DAY / this.meanmo;
  }

  get isDeepSpace(): boolean {
    return this.orbitalPeriod >= 225.0;
  }

  get epochDaynum(): number {
    return timeToDaynumOfEpoch(this.epoch);
  }

  hasDecayed(currentTimeMillis: number): boolean {
    if (this.ndot === 0.0) {
      return false;
    }
    return SatCelestialComputer.hasDecayed(this.meanmo, this.ndot, this.epochDaynum, timeToDaynum(currentTimeMillis));
  }
}

function julianDateOfYear(theYear: number): number {
  const aYear = theYear - 1;
  const a = Math.floor(aYear / 100);
  const b = 2 - a + a / 4;
  const i = Math.floor(365.25 * aYear);
  return i + Math.floor(30.6001 * 14) + 1720994.5 + b;
}

function timeToDaynumOfEpoch(epoch: number): number {
  let year = Math.floor(epoch * 1E-3);
  const day = (epoch * 1E-3 - year) * 1000.0;
  year = year < 57 ? year + 2000 : year + 1900;
  const jan1Jd = julianDateOfYear(year);
  return jan1Jd + day - 2444238.5;
}

/** Days since 31 Dec 1979 for a Unix epoch milliseconds timestamp. */
export function timeToDaynum(timeMillis: number): number {
  return (timeMillis - 315446400000) / 86400000.0;
}