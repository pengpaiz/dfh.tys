/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 */

import {
  ASTRONOMICAL_UNIT, DEG2RAD, EARTH_RADIUS, EPSILON, FLAT_FACT, MIN_PER_DAY, PI, PI_2,
  SEC_PER_DAY, SOLAR_RADIUS, TWO_PI
} from './Constants';
import { SatOrbitalData } from './OrbitalData';
import { SatGeoPos } from './GeoPos';
import { SatOrbitalPos } from './OrbitalPos';
import { modulus, mod2PI, thetaGJD, deltaET } from '../../common/utils/MathUtils';

export class SatVector4 {
  w: number;
  x: number;
  y: number;
  z: number;

  constructor(w: number = 0.0, x: number = 0.0, y: number = 0.0, z: number = 0.0) {
    this.w = w;
    this.x = x;
    this.y = y;
    this.z = z;
  }

  multiply(multiplier: number): void {
    this.x *= multiplier;
    this.y *= multiplier;
    this.z *= multiplier;
  }

  setXYZ(xValue: number, yValue: number, zValue: number): void {
    this.x = xValue;
    this.y = yValue;
    this.z = zValue;
  }
}

export abstract class SatOrbitalObject {
  data: SatOrbitalData;

  private position: SatVector4 = new SatVector4();
  private velocity: SatVector4 = new SatVector4();
  private orbitalPos: SatOrbitalPos = new SatOrbitalPos();
  private eclipseDepth = 0.0;
  private gsPosTheta = 0.0;
  private julUTC = 0.0;
  private perigee = 0.0;
  qoms24 = 0.0;
  s4 = 0.0;

  protected obsPos: SatVector4 = new SatVector4();
  protected obsVel: SatVector4 = new SatVector4();
  protected rangeVector: SatVector4 = new SatVector4();
  protected rgvelVector: SatVector4 = new SatVector4();
  protected squintVector: SatVector4 = new SatVector4();

  private cachedGsLat = Number.NaN;
  private cachedGsLon = Number.NaN;
  private cachedGsAlt = Number.NaN;
  private cachedSinLat = 0.0;
  private cachedCosLat = 0.0;
  private cachedObsC = 0.0;
  private cachedObsSq = 0.0;
  private cachedObsAchFactor = 0.0;
  private cachedObsZFactor = 0.0;

  private julEpoch: number = 0;

  constructor(data2: SatOrbitalData) {
    this.data = data2;
    this.julEpoch = juliandDateOfEpochStatic(data2.epoch);
  }

  /** Subclasses implement SGP4 (NearEarth) or SDP4 (DeepSpace) propagation. */
  protected abstract propagate(tSince: number): void;

  willBeSeen(pos: SatGeoPos): boolean {
    if (this.data.meanmo < 1e-8) {
      return false;
    }
    const sma = 331.25 * Math.exp(Math.log(MIN_PER_DAY / this.data.meanmo) * (2.0 / 3.0));
    const apogee = sma * (1.0 + this.data.eccn) - EARTH_RADIUS;
    let lin = this.data.incl;
    if (lin >= 90.0) {
      lin = 180.0 - lin;
    }
    return Math.acos(EARTH_RADIUS / (apogee + EARTH_RADIUS)) + lin * DEG2RAD > Math.abs(pos.latitude * DEG2RAD);
  }

  getPosition(pos: SatGeoPos, time: number): SatOrbitalPos {
    this.orbitalPos = new SatOrbitalPos();
    this.julUTC = this.calcCurrentDaynum(time) + 2444238.5;
    const tsince = (this.julUTC - this.julEpoch) * MIN_PER_DAY;
    this.propagate(tsince);
    this.convertSatState(this.position, this.velocity);
    this.magnitude(this.velocity);
    this.calculateObs(this.julUTC, this.position, this.velocity, pos, this.squintVector);
    this.calculateLatLonAlt(this.julUTC);
    this.orbitalPos.time = time;
    this.orbitalPos.eclipsed = this.isEclipsed();
    this.orbitalPos.eclipseDepth = this.eclipseDepth;
    return this.orbitalPos;
  }

  getElevation(pos: SatGeoPos, time: number): number {
    this.julUTC = this.calcCurrentDaynum(time) + 2444238.5;
    const tsince = (this.julUTC - this.julEpoch) * MIN_PER_DAY;
    this.propagate(tsince);
    this.convertSatState(this.position, this.velocity);
    this.magnitude(this.velocity);
    this.calculateObs(this.julUTC, this.position, this.velocity, pos, this.squintVector);
    return this.orbitalPos.elevation;
  }

  getFullPosition(pos: SatGeoPos, time: number): SatOrbitalPos {
    this.orbitalPos = new SatOrbitalPos();
    this.julUTC = this.calcCurrentDaynum(time) + 2444238.5;
    const tsince = (this.julUTC - this.julEpoch) * MIN_PER_DAY;
    this.propagate(tsince);
    this.convertSatState(this.position, this.velocity);
    this.magnitude(this.velocity);
    this.calculateObs(this.julUTC, this.position, this.velocity, pos, this.squintVector);
    this.calculateLatLonAlt(this.julUTC);
    this.orbitalPos.time = time;
    this.orbitalPos.eclipsed = this.isEclipsed();
    this.orbitalPos.eclipseDepth = this.eclipseDepth;
    return this.orbitalPos;
  }

  private calcCurrentDaynum(now: number): number {
    const then = 315446400000;
    return (now - then) / 1000.0 / 60.0 / 60.0 / 24.0;
  }

  protected convertSatState(pos: SatVector4, vel: SatVector4): void {
    this.scaleVector(EARTH_RADIUS, pos);
    this.scaleVector(EARTH_RADIUS * MIN_PER_DAY / SEC_PER_DAY, vel);
  }

  protected calculateObs(
    julianUTC: number,
    positionVector: SatVector4,
    velocityVector: SatVector4,
    gsPos: SatGeoPos,
    squintVector: SatVector4
  ): void {
    this.calculateUserPosVel(julianUTC, gsPos, this.obsPos, this.obsVel);
    this.rangeVector.setXYZ(
      positionVector.x - this.obsPos.x,
      positionVector.y - this.obsPos.y,
      positionVector.z - this.obsPos.z
    );
    squintVector.setXYZ(this.rangeVector.x, this.rangeVector.y, this.rangeVector.z);
    this.rgvelVector.setXYZ(
      velocityVector.x - this.obsVel.x,
      velocityVector.y - this.obsVel.y,
      velocityVector.z - this.obsVel.z
    );
    this.magnitude(this.rangeVector);
    const sinLat = this.cachedSinLat;
    const cosLat = this.cachedCosLat;
    const sinTheta = Math.sin(this.gsPosTheta);
    const cosTheta = Math.cos(this.gsPosTheta);
    const topS = sinLat * cosTheta * this.rangeVector.x + sinLat * sinTheta * this.rangeVector.y -
      cosLat * this.rangeVector.z;
    const topE = -sinTheta * this.rangeVector.x + cosTheta * this.rangeVector.y;
    const topZ = cosLat * cosTheta * this.rangeVector.x + cosLat * sinTheta * this.rangeVector.y +
      sinLat * this.rangeVector.z;
    let azim = Math.atan(-topE / topS);
    if (topS > 0.0) {
      azim += PI;
    }
    if (azim < 0.0) {
      azim += TWO_PI;
    }
    this.orbitalPos.azimuth = azim;
    this.orbitalPos.elevation = Math.asin(topZ / this.rangeVector.w);
    this.orbitalPos.distance = this.rangeVector.w;
    this.orbitalPos.distanceRate = this.dot(this.rangeVector, this.rgvelVector) / this.rangeVector.w;
    let elevation = this.orbitalPos.elevation / TWO_PI * 360.0;
    if (elevation > 90) {
      elevation = 180 - elevation;
    }
    this.orbitalPos.aboveHorizon = elevation - 0 > EPSILON;
  }

  private calculateUserPosVel(
    time: number,
    gsPos: SatGeoPos,
    obsPos: SatVector4,
    obsVel: SatVector4
  ): void {
    const mFactor = 7.292115E-5;
    this.gsPosTheta = mod2PI(thetaGJD(time) + DEG2RAD * gsPos.longitude);

    if (gsPos.latitude !== this.cachedGsLat || gsPos.longitude !== this.cachedGsLon || gsPos.altitude !== this.cachedGsAlt) {
      this.cachedGsLat = gsPos.latitude;
      this.cachedGsLon = gsPos.longitude;
      this.cachedGsAlt = gsPos.altitude;
      this.cachedSinLat = Math.sin(DEG2RAD * gsPos.latitude);
      this.cachedCosLat = Math.cos(DEG2RAD * gsPos.latitude);
      this.cachedObsC = 1.0 / Math.sqrt(1.0 + FLAT_FACT * (FLAT_FACT - 2) * this.sqr(this.cachedSinLat));
      this.cachedObsSq = this.sqr(1.0 - FLAT_FACT) * this.cachedObsC;
      this.cachedObsAchFactor = (EARTH_RADIUS * this.cachedObsC + gsPos.altitude / 1000.0) * this.cachedCosLat;
      this.cachedObsZFactor = (EARTH_RADIUS * this.cachedObsSq + gsPos.altitude / 1000.0) * this.cachedSinLat;
    }

    obsPos.setXYZ(
      this.cachedObsAchFactor * Math.cos(this.gsPosTheta),
      this.cachedObsAchFactor * Math.sin(this.gsPosTheta),
      this.cachedObsZFactor
    );
    obsVel.setXYZ(-mFactor * obsPos.y, mFactor * obsPos.x, 0.0);
    this.magnitude(obsPos);
    this.magnitude(obsVel);
  }

  private calculateLatLonAlt(time: number): void {
    this.orbitalPos.theta = Math.atan2(this.position.y, this.position.x);
    this.orbitalPos.longitude = mod2PI(this.orbitalPos.theta - thetaGJD(time));
    if (this.orbitalPos.longitude > PI) {
      this.orbitalPos.longitude -= TWO_PI;
    }
    const r = Math.sqrt(this.sqr(this.position.x) + this.sqr(this.position.y));
    const e2 = FLAT_FACT * (2.0 - FLAT_FACT);
    this.orbitalPos.latitude = Math.atan2(this.position.z, r);
    let phi: number;
    let c: number;
    let i = 0;
    let converged: boolean = false;
    do {
      phi = this.orbitalPos.latitude;
      c = 1.0 / Math.sqrt(1.0 - e2 * this.sqr(Math.sin(phi)));
      this.orbitalPos.latitude = Math.atan2(this.position.z + EARTH_RADIUS * c * e2 * Math.sin(phi), r);
      converged = Math.abs(this.orbitalPos.latitude - phi) < EPSILON;
      i++;
    } while (i < 11 && !converged);
    this.orbitalPos.altitude = r / Math.cos(this.orbitalPos.latitude) - EARTH_RADIUS * c;
    let temp = this.orbitalPos.latitude;
    if (temp > PI_2) {
      temp -= TWO_PI;
      this.orbitalPos.latitude = temp;
    }
  }

  protected calculatePosAndVel(
    rk: number, uk: number, xnodek: number,
    xinck: number, rdotk: number, rfdotk: number
  ): void {
    const sinuk = Math.sin(uk);
    const cosuk = Math.cos(uk);
    const sinik = Math.sin(xinck);
    const cosik = Math.cos(xinck);
    const sinnok = Math.sin(xnodek);
    const cosnok = Math.cos(xnodek);
    const xmx = -sinnok * cosik;
    const xmy = cosnok * cosik;
    const ux = xmx * sinuk + cosnok * cosuk;
    const uy = xmy * sinuk + sinnok * cosuk;
    const uz = sinik * sinuk;
    const vx = xmx * cosuk - cosnok * sinuk;
    const vy = xmy * cosuk - sinnok * sinuk;
    const vz = sinik * cosuk;
    this.position.setXYZ(ux, uy, uz);
    this.position.multiply(rk);
    this.velocity.x = rdotk * ux + rfdotk * vx;
    this.velocity.y = rdotk * uy + rfdotk * vy;
    this.velocity.z = rdotk * uz + rfdotk * vz;
  }

  protected sqr(arg: number): number {
    return arg * arg;
  }

  protected invert(value: number): number {
    return 1.0 / value;
  }

  protected converge(temp: number[], axn: number, ayn: number, capu: number): void {
    let converged = false;
    let i = 0;
    do {
      temp[7] = Math.sin(temp[2]);
      temp[8] = Math.cos(temp[2]);
      temp[3] = axn * temp[7];
      temp[4] = ayn * temp[8];
      temp[5] = axn * temp[8];
      temp[6] = ayn * temp[7];
      const epw = (capu - temp[4] + temp[3] - temp[2]) / (1.0 - temp[5] - temp[6]) + temp[2];
      if (Math.abs(epw - temp[2]) <= EPSILON) {
        converged = true;
      } else {
        temp[2] = epw;
      }
      i++;
    } while (i < 11 && !converged);
  }

  protected calculatePhase(xlt: number, xnode: number, omgadf: number): void {
    let phaseValue = xlt - xnode - omgadf + TWO_PI;
    if (phaseValue < 0.0) {
      phaseValue += TWO_PI;
    }
    this.orbitalPos.phase = mod2PI(phaseValue);
  }

  protected setPerigee(perigee: number): void {
    this.perigee = perigee;
    this.checkPerigee();
  }

  private checkPerigee(): void {
    this.s4 = 1.012229;
    this.qoms24 = 1.880279E-09;
    if (this.perigee < 156.0) {
      this.s4 = this.perigee <= 98.0 ? 20.0 : this.perigee - 78.0;
      this.qoms24 = Math.pow((120 - this.s4) / EARTH_RADIUS, 4.0);
      this.s4 = this.s4 / EARTH_RADIUS + 1.0;
    }
  }

  private isEclipsed(): boolean {
    const sunVector = this.calculateSunVector();
    const sdEarth = Math.asin(EARTH_RADIUS / this.position.w);
    const rho = this.subtract(sunVector, this.position);
    const sdSun = Math.asin(SOLAR_RADIUS / rho.w);
    const earth = this.scalarNegMultiply(this.position);
    const delta = this.angle(sunVector, earth);
    this.eclipseDepth = sdEarth - sdSun - delta;
    return sdEarth >= sdSun ? this.eclipseDepth >= 0 : false;
  }

  private calculateSunVector(): SatVector4 {
    const mjd = this.julUTC - 2415020.0;
    const year = 1900 + mjd / 365.25;
    const solTime = (mjd + deltaET(year) / SEC_PER_DAY) / 36525.0;
    const mTemp = modulus(35999.04975 * solTime, 360.0);
    const m = this.radians(
      modulus(358.47583 + mTemp - (0.000150 + 0.0000033 * solTime) * this.sqr(solTime), 360.0)
    );
    const lTemp = modulus(36000.76892 * solTime, 360.0);
    const l = this.radians(
      modulus(279.69668 + lTemp + 0.0003025 * this.sqr(solTime), 360.0)
    );
    const e = 0.01675104 - (0.0000418 + 0.000000126 * solTime) * solTime;
    const c = this.radians(
      ((1.919460 - (0.004789 + 0.000014 * solTime) * solTime) * Math.sin(m))
        + ((0.020094 - 0.000100 * solTime) * Math.sin(2 * m)) + 0.000293 * Math.sin(3 * m)
    );
    const o = this.radians(modulus(259.18 - 1934.142 * solTime, 360.0));
    const lsa = modulus(l + c - this.radians(0.00569 - 0.00479 * Math.sin(o)), TWO_PI);
    const nu = modulus(m + c, TWO_PI);
    let r = (1.0000002 * (1.0 - this.sqr(e)) / (1.0 + e * Math.cos(nu)));
    const eps = this.radians(
      23.452294 - (0.0130125 + (0.00000164 - 0.000000503 * solTime) * solTime)
        * solTime + 0.00256 * Math.cos(o)
    );
    r *= ASTRONOMICAL_UNIT;
    return new SatVector4(r, r * Math.cos(lsa), r * Math.sin(lsa) * Math.cos(eps), r * Math.sin(lsa) * Math.sin(eps));
  }

  private subtract(v1: SatVector4, v2: SatVector4): SatVector4 {
    const v3 = new SatVector4();
    v3.x = v1.x - v2.x;
    v3.y = v1.y - v2.y;
    v3.z = v1.z - v2.z;
    this.magnitude(v3);
    return v3;
  }

  private scalarNegMultiply(vector: SatVector4): SatVector4 {
    const neg = -1.0;
    return new SatVector4(vector.w * Math.abs(neg), vector.x * neg, vector.y * neg, vector.z * neg);
  }

  private angle(v1: SatVector4, v2: SatVector4): number {
    this.magnitude(v1);
    this.magnitude(v2);
    return Math.acos(this.dot(v1, v2) / (v1.w * v2.w));
  }

  private radians(degrees: number): number {
    return degrees * DEG2RAD;
  }

  private dot(v1: SatVector4, v2: SatVector4): number {
    return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z;
  }

  private magnitude(v: SatVector4): void {
    v.w = Math.sqrt(this.sqr(v.x) + this.sqr(v.y) + this.sqr(v.z));
  }

  private scaleVector(k: number, v: SatVector4): void {
    v.multiply(k);
    this.magnitude(v);
  }
}

function juliandDateOfYearStatic(year: number): number {
  const aYear = year - 1;
  let i = Math.floor(aYear / 100);
  const a = i;
  i = Math.floor(a / 4);
  const b = 2 - a + i;
  i = Math.floor(365.25 * aYear);
  i += Math.floor(30.6001 * 14);
  return i + 1720994.5 + b;
}

function juliandDateOfEpochStatic(epoch: number): number {
  let year = Math.floor(epoch * 1E-3);
  const day = (epoch * 1E-3 - year) * 1000.0;
  year = year < 57 ? year + 2000 : year + 1900;
  return juliandDateOfYearStatic(year) + day;
}