/*
 * Look4Sat. Shared selected-satellites state across bottom tabs.
 * Held in AppStorage so tab1 (satellites) and tab2 (passes) stay in sync.
 */

const CATS_KEY = 'selected_cats';
const VERSION_KEY = 'selected_version';

export class SelectedSats {
  /**
   * 只恢复持久化状态，首启不预置任何卫星。
   * 若默认选中某颗星（如 ISS），用户一进应用就能看到"已有过境/观测数据"，
   * 会被当成预置测试数据，因此选择集必须从空开始、由用户自行点选。
   */
  static init(): void {
    PersistentStorage.persistProp(CATS_KEY, new Array<number>());
    PersistentStorage.persistProp(VERSION_KEY, 0);
  }

  static getCats(): number[] {
    const cats = AppStorage.get<number[]>(CATS_KEY);
    return cats === undefined ? [] : cats;
  }

  static isSelected(catnum: number): boolean {
    const cats = SelectedSats.getCats();
    return cats.indexOf(catnum) >= 0;
  }

  static toggle(catnum: number): void {
    const cats = SelectedSats.getCats();
    const idx = cats.indexOf(catnum);
    if (idx >= 0) {
      cats.splice(idx, 1);
    } else {
      cats.push(catnum);
    }
    // store a fresh copy so AppStorage / @StorageLink detect the change
    AppStorage.setOrCreate<number[]>(CATS_KEY, Array.from(cats));
    SelectedSats.bumpVersion();
  }

  static clear(): void {
    AppStorage.setOrCreate<number[]>(CATS_KEY, []);
    SelectedSats.bumpVersion();
  }

  static bumpVersion(): void {
    const v = AppStorage.get<number>(VERSION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(VERSION_KEY, v + 1);
  }

  static getVersion(): number {
    return AppStorage.get<number>(VERSION_KEY) ?? 0;
  }
}