/*
 * Look4Sat. Device GPS location helper using Location Kit.
 */

import { geoLocationManager } from '@kit.LocationKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SatGeoPos } from '../domain/predict/GeoPos';

const LOCATION_PERMISSIONS: Permissions[] = [
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

export class Locator {
  /**
   * 海拔是否可信。首次定位（尤其是网络辅助首修）常把海拔给成 0 或明显离谱的值，
   * 用它覆盖用户已保存的海拔会把站址算错，所以调用方要先判断。
   */
  static altitudeIsUsable(alt: number): boolean {
    return Number.isFinite(alt) && alt > -500 && alt < 9000;
  }

  /**
   * Request location permission if missing, then fetch current position.
   * [highAccuracy] 为 true 时用高精度请求（更慢，但海拔可信）。
   * Returns null on failure / denial.
   */
  static async getCurrentPosition(context: common.Context, highAccuracy: boolean = false): Promise<SatGeoPos | null> {
    if (!await Locator.ensurePermission(context)) {
      return null;
    }
    return await Locator.fetch(highAccuracy);
  }

  private static async ensurePermission(context: common.Context): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const req = await atManager.requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
      for (let i = 0; i < req.authResults.length; i++) {
        if (req.authResults[i] === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
          return false;
        }
      }
      return req.authResults.length > 0;
    } catch (e) {
      return false;
    }
  }

  private static fetch(highAccuracy: boolean): Promise<SatGeoPos | null> {
    return new Promise<SatGeoPos | null>((resolve) => {
      const request: geoLocationManager.CurrentLocationRequest = {
        priority: highAccuracy
          ? geoLocationManager.LocationRequestPriority.ACCURACY
          : geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: highAccuracy
          ? geoLocationManager.LocationRequestScenario.NAVIGATION
          : geoLocationManager.LocationRequestScenario.TRAJECTORY_TRACKING,
        maxAccuracy: 0,
        timeoutMs: highAccuracy ? 20000 : 10000
      };
      try {
        geoLocationManager.getCurrentLocation(request, (err: BusinessError, loc: geoLocationManager.Location) => {
          if (err) {
            resolve(null);
            return;
          }
          resolve(new SatGeoPos(loc.latitude, loc.longitude, loc.altitude ?? 0, 'gps'));
        });
      } catch (e) {
        resolve(null);
      }
    });
  }
}