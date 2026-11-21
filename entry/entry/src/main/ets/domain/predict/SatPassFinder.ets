/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Pass prediction ported from the upstream Android Look4Sat algorithm
 * (getPasses / getLeoPass / getGeoPass in SatelliteRepo.kt).
 */

import { SatOrbitalObject } from './OrbitalObject';
import { SatGeoPos } from './GeoPos';
import { toDegrees } from '../../common/utils/MathUtils';

export class SatPassEvent {
  aosTime: number;
  aosAzimuth: number;
  losTime: number;
  losAzimuth: number;
  maxElevationDeg: number;
  altitudeKm: number;

  constructor(aosTime: number, aosAzimuth: number, losTime: number, losAzimuth: number,
              maxElevationDeg: number, altitudeKm: number) {
    this.aosTime = aosTime;
    this.aosAzimuth = aosAzimuth;
    this.losTime = losTime;
    this.losAzimuth = losAzimuth;
    this.maxElevationDeg = maxElevationDeg;
    this.altitudeKm = altitudeKm;
  }

  get durationMillis(): number {
    return this.losTime - this.aosTime;
  }
}

export class SatPassFinder {
  /**
   * Calculate passes for one satellite from [time] for [hours] ahead.
   * Faithful port of the upstream Look4Sat algorithm.
   */
  getPasses(obj: SatOrbitalObject, pos: SatGeoPos, time: number, hours: number): SatPassEvent[] {
    const passes: SatPassEvent[] = [];
    const endDate = time + hours * 60 * 60 * 1000;
    if (obj.data.hasDecayed(time)) {
      return passes;
    }
    const period = obj.data.orbitalPeriod;
    const quarterOrbitMin = Math.floor(period / 4.0);
    let startDate = time;
    let shouldRewind = true;
    let count = 0;
    if (obj.willBeSeen(pos)) {
      if (obj.data.isDeepSpace) {
        passes.push(this.getGeoPass(obj, pos, time));
      } else {
        let lastAosDate: number;
        do {
          if (count > 0) {
            shouldRewind = false;
          }
          const pass = this.getLeoPass(obj, pos, startDate, shouldRewind, endDate);
          if (pass === null) {
            break;
          }
          lastAosDate = pass.aosTime;
          passes.push(pass);
          startDate = pass.losTime + (quarterOrbitMin * 3) * 60 * 1000;
          count++;
        } while (lastAosDate < endDate && count < 200);
      }
    }
    passes.sort((a: SatPassEvent, b: SatPassEvent): number => a.aosTime - b.aosTime);
    return passes;
  }

  private getGeoPass(sat: SatOrbitalObject, pos: SatGeoPos, time: number): SatPassEvent {
    const satPos = sat.getPosition(pos, time);
    const aos = time - 24 * 60 * 60 * 1000;
    const los = time + 24 * 60 * 60 * 1000;
    const az = this.roundDeg(toDegrees(satPos.azimuth));
    const elev = this.roundDeg(toDegrees(satPos.elevation));
    return new SatPassEvent(aos, az, los, az, elev, satPos.altitude);
  }

  private getLeoPass(sat: SatOrbitalObject, pos: SatGeoPos, time: number, rewind: boolean,
                     endDate: number): SatPassEvent | null {
    const quarterOrbitMin = Math.floor(sat.data.orbitalPeriod / 4.0);
    const searchLimit = endDate + Math.ceil(sat.data.orbitalPeriod) * 60 * 1000;
    let calendarTimeMillis = time;
    let elevation: number;
    let maxElevation = 0.0;
    if (rewind) {
      calendarTimeMillis -= quarterOrbitMin * 60 * 1000;
    }

    // coarse: if already above horizon, step forward until below
    if (sat.getElevation(pos, calendarTimeMillis) > 0.0) {
      do {
        calendarTimeMillis += 30 * 1000;
        if (calendarTimeMillis > searchLimit) {
          return null;
        }
      } while (sat.getElevation(pos, calendarTimeMillis) > 0.0);
      calendarTimeMillis += quarterOrbitMin * 3 * 60 * 1000;
    }

    // find next time above horizon (coarse 60s)
    do {
      calendarTimeMillis += 60 * 1000;
      if (calendarTimeMillis > endDate) {
        return null;
      }
      elevation = sat.getElevation(pos, calendarTimeMillis);
      if (!Number.isFinite(elevation)) {
        return null;
      }
      if (elevation > maxElevation) {
        maxElevation = elevation;
      }
    } while (elevation < 0.0);

    // refine AOS to ~500ms
    calendarTimeMillis -= 60 * 1000;
    do {
      calendarTimeMillis += 500;
      elevation = sat.getElevation(pos, calendarTimeMillis);
      if (!Number.isFinite(elevation)) {
        return null;
      }
      if (elevation > maxElevation) {
        maxElevation = elevation;
      }
    } while (elevation < 0.0);

    const aosPos = sat.getFullPosition(pos, calendarTimeMillis);
    const aos = 1000 * Math.round((aosPos.time + 500) / 1000);
    const aosAz = this.roundDeg(toDegrees(aosPos.azimuth));

    // coarse below horizon (30s)
    do {
      calendarTimeMillis += 30 * 1000;
      elevation = sat.getElevation(pos, calendarTimeMillis);
      if (!Number.isFinite(elevation)) {
        break;
      }
      if (elevation > maxElevation) {
        maxElevation = elevation;
      }
    } while (elevation > 0.0 && calendarTimeMillis < searchLimit);

    // refine LOS to ~500ms
    calendarTimeMillis -= 30 * 1000;
    do {
      calendarTimeMillis += 500;
      elevation = sat.getElevation(pos, calendarTimeMillis);
      if (!Number.isFinite(elevation)) {
        break;
      }
      if (elevation > maxElevation) {
        maxElevation = elevation;
      }
    } while (elevation > 0.0 && calendarTimeMillis < searchLimit);

    const losPos = sat.getFullPosition(pos, calendarTimeMillis);
    const los = 1000 * Math.round((losPos.time + 500) / 1000);
    const losAz = this.roundDeg(toDegrees(losPos.azimuth));

    if (!Number.isFinite(aos) || !Number.isFinite(los) || !Number.isFinite(maxElevation)) {
      return null;
    }

    const tcaTime = (aos + los) / 2;
    const tcaPos = sat.getFullPosition(pos, tcaTime);
    const alt = tcaPos.altitude;

    const elev = this.roundDeg(toDegrees(maxElevation));
    return new SatPassEvent(aos, aosAz, los, losAz, elev, alt);
  }

  private roundDeg(value: number): number {
    return Math.round(value * 10) / 10;
  }
}