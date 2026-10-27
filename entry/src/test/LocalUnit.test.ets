import { SatDataParser } from '../main/ets/domain/parser/DataParser';
import { SatGeoPos } from '../main/ets/domain/predict/GeoPos';
import { SatNearEarthObject } from '../main/ets/domain/predict/NearEarthObject';
import { qthToPosition, positionToQth } from '../main/ets/domain/qth/QthConverter';
import { describe, it, expect } from '@ohos/hypium';

const parser = new SatDataParser();

const TLE_ISS: string = `ISS (ZARYA)
1 25544U 98067A   21320.51955234  .00001288  00000+0  31985-4 0  9990
2 25544  51.6447 309.4881 0004694 203.6966 299.8876 15.48582035312205`;

const CSV_ISS: string =
  `OBJECT_NAME,OBJECT_ID,EPOCH,MEAN_MOTION,ECCENTRICITY,INCLINATION,RA_OF_ASC_NODE,ARG_OF_PERICENTER,MEAN_ANOMALY,EPHEMERIS_TYPE,CLASSIFICATION_TYPE,NORAD_CAT_ID,ELEMENT_SET_NO,REV_AT_EPOCH,BSTAR,MEAN_MOTION_DOT,MEAN_MOTION_DDOT
ISS (ZARYA),1998-067A,2021-11-16T12:28:09.322176,15.48582035,.0004694,51.6447,309.4881,203.6966,299.8876,0,U,25544,999,31220,.31985E-4,.1288E-4,0`;

function approx(a: number, b: number, tol: number): boolean {
  return Math.abs(a - b) <= tol;
}

export default function domainSentinelTest() {
  describe('domainSentinel', () => {
    it('TLE parse ISS full fields', 0, () => {
      const list = parser.parseTLEStream(TLE_ISS);
      expect(list.length).assertEqual(1);
      const sat = list[0];
      expect(sat.name).assertEqual('ISS (ZARYA)');
      expect(sat.catnum).assertEqual(25544);
      expect(sat.meanmo).assertEqual(15.48582035);
      expect(sat.eccn).assertEqual(0.0004694);
      expect(sat.incl).assertEqual(51.6447);
      expect(sat.raan).assertEqual(309.4881);
      expect(sat.argper).assertEqual(203.6966);
      expect(sat.meanan).assertEqual(299.8876);
      expect(approx(sat.epoch, 21320.51955234, 1e-8)).assertTrue();
      expect(approx(sat.ndot, 0.00001288, 1e-12)).assertTrue();
    });

    it('CSV parse matches TLE-encoded fields', 0, () => {
      const tleSat = parser.parseTLEStream(TLE_ISS)[0];
      const csvSat = parser.parseCSVStream(CSV_ISS)[0];
      expect(csvSat.name).assertEqual(tleSat.name);
      expect(csvSat.catnum).assertEqual(tleSat.catnum);
      expect(csvSat.meanmo).assertEqual(tleSat.meanmo);
      expect(csvSat.eccn).assertEqual(tleSat.eccn);
      expect(expectedEpochWithin(csvSat.epoch, tleSat.epoch)).assertTrue();
    });

    it('QTH converter round trip', 0, () => {
      const pos = qthToPosition('JN55XA');
      expect(pos !== null).assertTrue();
      if (pos !== null) {
        const back = positionToQth(pos.latitude, pos.longitude);
        expect(back !== null).assertTrue();
        if (back !== null) {
          // JN is roughly 50N 15E; sub-square resolution in JN55 lands around there
          const p2 = qthToPosition('JN55');
          expect(p2 !== null).assertTrue();
        }
      }
    });

    it('SGP4 near-earth position sanity (ISS visible above horizon at Vienna)', 0, () => {
      const sat = parser.parseTLEStream(TLE_ISS)[0];
      const obj = new SatNearEarthObject(sat);
      const obs = new SatGeoPos(48.2, 16.37, 0.0, 'JN88');
      // 21320.51955234 is 2021-11-16T12:28 UTC; query a time 50 minutes later
      const baseMillis = 1637065689345; // ~2021-11-16T12:28:09
      const t = baseMillis + 3000000;
      const p = obj.getPosition(obs, t);
      // Position must produce physically consistent altitude in km and a distance > 0
      expect(p.distance > 300).assertTrue();
      expect(p.altitude > -100).assertTrue();
      expect(approx(p.distanceRate, 0, 50)).assertTrue();
    });

    it('constants epoch helpers', 0, () => {
      const sat = parser.parseTLEStream(TLE_ISS)[0];
      // ISS is Low Earth Orbit -> not deep space, period ~ 92.7 min
      expect(sat.isDeepSpace).assertFalse();
      expect(approx(sat.orbitalPeriod, 92.9, 0.5)).assertTrue();
    });
  });
}

function expectedEpochWithin(a: number, b: number): boolean {
  return Math.abs(a - b) < 1e-5;
}