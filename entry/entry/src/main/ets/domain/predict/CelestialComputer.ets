/*
 * Look4Sat. Amateur radio satellite tracker and pass predictor.
 * Ported to HarmonyOS ArkTS from the Android Kotlin original (GPL-3.0).
 *
 * 说明：这里仅保留当前实际被引用的过境判定。移植带来的太阳/月亮位置、升落时间、
 * 可见性分类、目视星等、相位角、多普勒频移等实现确无调用方（已核查），此处移除；
 * 若后续需要相关能力，可从上游 PREDICT/Look4Sat 恢复。
 */

export class SatCelestialComputer {
  /** 轨道是否已衰变（半长轴收缩至再入）：用于预报上界判定。 */
  static hasDecayed(meanMotion: number, drag: number, epochDaynum: number, currentDaynum: number): boolean {
    return epochDaynum + ((16.666666 - meanMotion) / (10.0 * Math.abs(drag))) < currentDaynum;
  }
}