/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Poll unionity: create the right SGP4/SDP4 propagator for a satellite.
 *
 * 走 OrbitalObjectCache：同一颗星（同一 TLE 历元）全局只解析/初始化一次，
 * 过境预测、日历、地图、详情页共用同一个对象（§16/§17）。
 */

import { SatOrbitalData } from './OrbitalData';
import { SatOrbitalObject } from './OrbitalObject';
import { SatNearEarthObject } from './NearEarthObject';
import { SatDeepSpaceObject } from './DeepSpaceObject';
import { OrbitalObjectCache } from './OrbitalObjectCache';

export function createOrbitalObject(data: SatOrbitalData): SatOrbitalObject {
  const cache = OrbitalObjectCache.getInstance();
  const cached = cache.get(data);
  if (cached !== null) {
    return cached;
  }
  const obj: SatOrbitalObject = data.isDeepSpace
    ? new SatDeepSpaceObject(data)
    : new SatNearEarthObject(data);
  cache.put(data, obj);
  return obj;
}
