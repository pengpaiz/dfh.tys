/*
 * Look4Sat. Compute radar projection (azimuth/elevation -> x,y) and pass track.
 */

import { SatOrbitalObject } from './OrbitalObject';
import { SatGeoPos } from './GeoPos';
import { SatOrbitalPos } from './OrbitalPos';
import { SatPassEvent } from './SatPassFinder';
import { toRadians } from '../../common/utils/MathUtils';

export const PI_2 = Math.PI / 2.0;

/** Polar point for a radar of given radius in vp units. */
export class RadarPoint {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

/** Project (azimuth_rad, elevation_rad) onto a radar circle of [radius]. */
export function sph2Cart(azimRad: number, elevRad: number, radius: number): RadarPoint {
  const r = radius * (PI_2 - elevRad) / PI_2;
  return new RadarPoint(
    r * Math.cos(PI_2 - azimRad),
    -r * Math.sin(PI_2 - azimRad)
  );
}

export function sph2CartDeg(azimDeg: number, elevDeg: number, radius: number): RadarPoint {
  return sph2Cart(toRadians(azimDeg), toRadians(elevDeg), radius);
}

/**
 * Sample satellite positions across a pass to build the radar track.
 * Returns [x, y, elevation] arrays relative to a [radius] radar circle.
 */
export function buildPassTrack(obj: SatOrbitalObject, station: SatGeoPos,
                               pass: SatPassEvent, radius: number,
                               samples: number = 60): RadarTrackResult {
  const xs: number[] = [];
  const ys: number[] = [];
  const elevs: number[] = [];
  const step = (pass.losTime - pass.aosTime) / samples;
  for (let i = 0; i <= samples; i++) {
    const t = pass.aosTime + i * step;
    const pos = obj.getPosition(station, t);
    const pt = sph2Cart(pos.azimuth, pos.elevation, radius);
    xs.push(pt.x);
    ys.push(pt.y);
    elevs.push(pos.elevation);
  }
  return new RadarTrackResult(xs, ys, elevs);
}

export class RadarTrackResult {
  xs: number[];
  ys: number[];
  elevs: number[];

  constructor(xs: number[], ys: number[], elevs: number[]) {
    this.xs = xs;
    this.ys = ys;
    this.elevs = elevs;
  }
}

/** Detailed info for one pass to display in the radar detail sheet. */
export class PassDetailData {
  catnum: number;
  name: string;
  aosTime: number;
  aosAzimuth: number;
  losTime: number;
  losAzimuth: number;
  maxElevationDeg: number;
  durationMin: number;
  tcaTime: number;
  pos: SatOrbitalPos;
  downlinkFreqs: FreqInfo[];
  uplinkFreqs: FreqInfo[];

  constructor(catnum: number, name: string, aosTime: number, aosAzimuth: number, losTime: number,
              losAzimuth: number, maxElevationDeg: number, durationMin: number, tcaTime: number,
              pos: SatOrbitalPos, downlinkFreqs: FreqInfo[], uplinkFreqs: FreqInfo[]) {
    this.catnum = catnum;
    this.name = name;
    this.aosTime = aosTime;
    this.aosAzimuth = aosAzimuth;
    this.losTime = losTime;
    this.losAzimuth = losAzimuth;
    this.maxElevationDeg = maxElevationDeg;
    this.durationMin = durationMin;
    this.tcaTime = tcaTime;
    this.pos = pos;
    this.downlinkFreqs = downlinkFreqs;
    this.uplinkFreqs = uplinkFreqs;
  }
}

export class FreqInfo {
  mode: string;
  display: string;

  constructor(mode: string, display: string) {
    this.mode = mode;
    this.display = display;
  }
}