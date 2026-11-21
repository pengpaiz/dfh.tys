import { SatelliteApp } from '../../common/SatelliteApp';
import { SatelliteDataSource } from '../../data/storage/SatelliteStore';
import { SatOrbitalData } from '../../domain/predict/OrbitalData';
import { promptAction } from '@kit.ArkUI';
import { ISS_CATNUM } from '../../common/SatelliteApp';
import { AppSettings } from '../../common/AppSettings';
import { SatelliteDownloader } from '../../data/downloader/SatelliteDownloader';
import { SelectedSats } from '../../common/SelectedSats';
import { Favorites } from '../../common/Favorites';
import { ENTER_SCALE, PRESS_IN_MS, PRESS_OUT_MS, PRESS_SCALE } from '../components/PressFx';
import { KEY_BAR_CLEARANCE, TAB_BAR_CLEARANCE } from '../../common/LayoutMetrics';

/** 查询串是否纯数字：只有纯数字才需要比 NORAD 编号。 */
function isDigits(q: string): boolean {
  if (q.length === 0) {
    return false;
  }
  for (let i = 0; i < q.length; i++) {
    const c = q.charCodeAt(i);
    if (c < 48 || c > 57) {
      return false;
    }
  }
  return true;
}

@Component
export struct SatelliteListPage {
  @State loading: boolean = false;
  @State selectedCount: number = 0;
  @State unselectedCount: number = 0;
  @StorageLink('selected_cats') selectedCats: number[] = [];
  @StorageProp('selected_version') @Watch('onSelectionChanged') selVersion: number = 0;
  @StorageLink('data_version') @Watch('onDataChanged') dataVersion: number = 0;

  @State sheetVisible: boolean = false;
  /** true = 搜索面板，false = 收藏夹面板（同一节点只能绑一个 bindSheet，用标记区分内容） */
  @State sheetIsSearch: boolean = true;
  @State searchQuery: string = '';
  @State searchResults: SatOrbitalData[] = [];
  @State pressedBtn: string = '';
  @State btnEntered: boolean = false;
  /** 收藏集（与「已选择」独立）：星标与收藏夹面板都读它 */
  @StorageLink('favorite_cats') favoriteCats: number[] = [];
  /** 收藏夹面板打开时的快照：面板内取消收藏不会让该行立刻消失 */
  @State favList: number[] = [];
  /** 底部预留（由 Index 按栏高+导航条避让算出后发布），保证与其它页一致 */
  @StorageProp(KEY_BAR_CLEARANCE) barClearance: number = TAB_BAR_CLEARANCE;

  private app: SatelliteApp = SatelliteApp.getInstance();
  private scroller: Scroller = new Scroller();
  private selectedSource: SatelliteDataSource = new SatelliteDataSource([]);
  private unselectedSource: SatelliteDataSource = new SatelliteDataSource([]);
  private selectedArr: SatOrbitalData[] = [];
  private unselectedArr: SatOrbitalData[] = [];
  private selectedSet: Set<number> = new Set<number>();
  /** 名称预排序结果 + 小写名称索引，仅在数据变化时重建。 */
  private orderedAll: SatOrbitalData[] = [];
  private nameKeys: string[] = [];
  /** 本次选择变更由增量搬移处理，跳过 onSelectionChanged 的整表重建 */
  private suppressRefresh: boolean = false;

  aboutToAppear(): void {
    this.reloadAll();
    // 无本地数据时由 Index 的 startupOfflineSeed 负责从内置快照离线播种；
    // 这里只在用户配置了自定义数据源地址时才自动联网更新（默认离线优先，不静默联网）。
    if (this.app.getStore().getAll().length === 0 && SatelliteDownloader.isUsableUrl(AppSettings.getCustomTleUrl())) {
      this.doAutoDownload();
    }
  }

  /** 卫星集变化（下载/导入）：重建排序与搜索索引后再刷新分组。 */
  onDataChanged(): void {
    this.reloadAll();
  }

  /** 选择集变化：无需重排，只要重新分组（增量路径会自行跳过）。 */
  onSelectionChanged(): void {
    if (this.suppressRefresh) {
      return;
    }
    this.refreshGroups();
  }

  private backToTop(): void {
    this.scroller.scrollEdge(Edge.Top);
  }

  /**
   * 一次性构建：按名称排序（用预计算的小写键做 < 比较，避免 localeCompare 的
   * ICU 开销）+ 与排序结果平行的小写名称数组，供搜索直接扫描、不再逐条 toLowerCase。
   */
  private buildIndex(): void {
    const all = this.app.getStore().getAll();
    const n = all.length;
    const keys: string[] = [];
    const order: number[] = [];
    for (let i = 0; i < n; i++) {
      keys.push(all[i].name.toLowerCase());
      order.push(i);
    }
    order.sort((a: number, b: number): number => {
      const ka = keys[a];
      const kb = keys[b];
      if (ka < kb) {
        return -1;
      }
      return ka > kb ? 1 : 0;
    });
    const arr: SatOrbitalData[] = [];
    const sortedKeys: string[] = [];
    for (let i = 0; i < n; i++) {
      const idx = order[i];
      arr.push(all[idx]);
      sortedKeys.push(keys[idx]);
    }
    this.orderedAll = arr;
    this.nameKeys = sortedKeys;
  }

  private reloadAll(): void {
    this.buildIndex();
    this.refreshGroups();
  }

  /**
   * 按「已选 / 未选」分组。
   * - 未选择：沿用名称预排序结果
   * - 已选择：按加入顺序（先选的在上，后选的追加到下面），顺序取自 selected_cats
   */
  private refreshGroups(): void {
    const set = new Set<number>();
    for (let i = 0; i < this.selectedCats.length; i++) {
      set.add(this.selectedCats[i]);
    }
    this.selectedSet = set;
    const others: SatOrbitalData[] = [];
    const byCat: Map<number, SatOrbitalData> = new Map<number, SatOrbitalData>();
    for (let i = 0; i < this.orderedAll.length; i++) {
      const s = this.orderedAll[i];
      if (set.has(s.catnum)) {
        byCat.set(s.catnum, s);
      } else {
        others.push(s);
      }
    }
    const selected: SatOrbitalData[] = [];
    for (let i = 0; i < this.selectedCats.length; i++) {
      const s = byCat.get(this.selectedCats[i]);
      if (s !== undefined) {
        selected.push(s);
      }
    }
    this.selectedArr = selected;
    this.unselectedArr = others;
    this.selectedSource.setData(selected);
    this.unselectedSource.setData(others);
    this.selectedCount = selected.length;
    this.unselectedCount = others.length;
  }

  /** 输入本身已按名称有序，这里只做「已选 / 未选」切分，保持各自有序。 */
  private splitBySelection(list: SatOrbitalData[]): SatOrbitalData[][] {
    const selected: SatOrbitalData[] = [];
    const others: SatOrbitalData[] = [];
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      if (this.selectedSet.has(s.catnum)) {
        selected.push(s);
      } else {
        others.push(s);
      }
    }
    return [selected, others];
  }

  /**
   * 选择/取消时走动画：让选中项从原位置飞到「已选择」分区（新选的落在该区末尾）。
   * 用增量搬移（add/delete 通知）而不是 setData 整表刷新，
   * 否则整个分区会在动画里重新挂载，表现为「列表项从上往下逐个淡入」。
   */
  private toggleSelected(catnum: number): void {
    const wasSelected = this.selectedSet.has(catnum);
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
      this.suppressRefresh = true;
      SelectedSats.toggle(catnum);
      this.moveRowIncremental(catnum, wasSelected);
      this.suppressRefresh = false;
    });
  }

  /** 只搬动变化的那一项：从源分区删除 + 插入到目标分区，各通知一次。 */
  private moveRowIncremental(catnum: number, wasSelected: boolean): void {
    if (!wasSelected) {
      const ui = this.indexOfCat(this.unselectedArr, catnum);
      if (ui < 0) {
        return;
      }
      const item = this.unselectedArr[ui];
      this.unselectedArr.splice(ui, 1);
      this.unselectedSource.notifyDataDelete(ui);
      this.selectedArr.push(item);
      this.selectedSet.add(catnum);
      this.selectedSource.notifyDataAdd(this.selectedArr.length - 1);
    } else {
      const si = this.indexOfCat(this.selectedArr, catnum);
      if (si < 0) {
        return;
      }
      const item = this.selectedArr[si];
      this.selectedArr.splice(si, 1);
      this.selectedSource.notifyDataDelete(si);
      // 未选择区按名称升序，二分找到插入位置，保持有序不整表重建
      const ins = this.nameInsertIndex(this.unselectedArr, item.name.toLowerCase());
      this.unselectedArr.splice(ins, 0, item);
      this.selectedSet.delete(catnum);
      this.unselectedSource.notifyDataAdd(ins);
    }
    this.selectedCount = this.selectedArr.length;
    this.unselectedCount = this.unselectedArr.length;
  }

  private indexOfCat(list: SatOrbitalData[], catnum: number): number {
    for (let i = 0; i < list.length; i++) {
      if (list[i].catnum === catnum) {
        return i;
      }
    }
    return -1;
  }

  /** 在按小写名称升序排列的列表里，找 key 的插入位置。 */
  private nameInsertIndex(list: SatOrbitalData[], key: string): number {
    let lo = 0;
    let hi = list.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      const mk = list[mid].name.toLowerCase();
      if (mk < key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  private async doAutoDownload(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      const count = await this.app.downloadAndStore();
      try {
        await this.app.downloadTranspondersAndStore();
      } catch (e) {
        // optional
      }
      this.reloadAll();
      if (count > 0) {
        const iss = this.app.getStore().getByCatnum(ISS_CATNUM);
        if (iss !== null && !SelectedSats.isSelected(ISS_CATNUM)) {
          SelectedSats.toggle(ISS_CATNUM);
        }
      }
    } catch (e) {
      // silent
    } finally {
      this.loading = false;
    }
  }

  private async doDownload(): Promise<void> {
    this.loading = true;
    try {
      const count = await this.app.downloadAndStore();
      try {
        await this.app.downloadTranspondersAndStore();
      } catch (e) {
        // optional
      }
      this.reloadAll();
      promptAction.showToast({ message: `已下载 ${count} 颗卫星` });
    } catch (e) {
      promptAction.showToast({ message: '下载失败，请检查网络' });
    } finally {
      this.loading = false;
    }
  }

  private async doImport(): Promise<void> {
    try {
      const count = await this.app.importAndStore(getContext(this));
      if (count < 0) {
        return;
      }
      this.reloadAll();
      promptAction.showToast({ message: `已导入 ${count} 颗卫星` });
    } catch (e) {
      promptAction.showToast({ message: '导入失败' });
    }
  }

  /** 🔍 弹出搜索框 */
  private openSearch(): void {
    this.searchQuery = '';
    this.searchResults = [];
    this.sheetIsSearch = true;
    this.sheetVisible = true;
  }

  /**
   * 直接扫描预排序 + 预小写的结果集：不再逐条 toLowerCase()，也顺带保证
   * 命中结果已按名称有序（无需再排序）；仅纯数字查询才比 NORAD 编号。
   */
  private applySearchQuery(): void {
    const q = this.searchQuery.trim().toLowerCase();
    if (q.length === 0) {
      this.searchResults = [];
      return;
    }
    if (this.orderedAll.length === 0) {
      this.buildIndex();
    }
    const numeric = isDigits(q);
    const arr = this.orderedAll;
    const keys = this.nameKeys;
    const list: SatOrbitalData[] = [];
    for (let i = 0; i < arr.length; i++) {
      const nameHit = keys[i].indexOf(q) >= 0;
      const numHit = numeric && String(arr[i].catnum).indexOf(q) >= 0;
      if (nameHit || numHit) {
        list.push(arr[i]);
        if (list.length >= 50) {
          break;
        }
      }
    }
    const groups = this.splitBySelection(list);
    this.searchResults = groups[0].concat(groups[1]);
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.selectedCount === 0 && this.unselectedCount === 0) {
          Column({ space: 12 }) {
            Text($r('app.string.empty_hint'))
              .fontColor($r('app.color.cc_text_muted'))
              .fontSize(14)
              .textAlign(TextAlign.Center)
            Button('下载数据')
              .onClick((): void => {
                this.doDownload()
              })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 8, scroller: this.scroller }) {
            if (this.selectedCount > 0) {
              ListItemGroup({
                header: this.sectionHeader('已选择', this.selectedCount),
                space: 8
              }) {
                LazyForEach(this.selectedSource, (item: SatOrbitalData) => {
                  ListItem() {
                    this.satRow(item)
                  }
                }, (item: SatOrbitalData): string => {
                  return String(item.catnum)
                })
              }
            }
            if (this.unselectedCount > 0) {
              ListItemGroup({
                header: this.sectionHeader('未选择', this.unselectedCount),
                space: 8
              }) {
                LazyForEach(this.unselectedSource, (item: SatOrbitalData) => {
                  ListItem() {
                    this.satRow(item)
                  }
                }, (item: SatOrbitalData): string => {
                  return String(item.catnum)
                })
              }
            }
            // 末尾占位项：给滚动内容留出胶囊栏的空间（放在内容里，而不是给 List 加 padding，
            // 否则会把 List 可视区缩小、底部永远空一条）
            ListItem() {
              Column().width('100%').height(this.barClearance)
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 14, right: 14 })
          .sticky(StickyStyle.Header)
          // 关闭右侧滚动条（仍可正常滑动）
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.cc_page_bg'))

      // 右下角圆形悬浮按钮
      this.floatingButtons()
    }
    .width('100%')
    .height('100%')
    .bindSheet($$this.sheetVisible, this.sheetBuilder(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE]
    })
  }

  /** 唯一的面板入口：按标记决定显示搜索还是收藏夹（同一节点只能绑一个 bindSheet） */
  @Builder
  private sheetBuilder() {
    if (this.sheetIsSearch) {
      this.searchSheetBuilder()
    } else {
      this.favSheetBuilder()
    }
  }

  @Builder
  private favSheetBuilder() {
    Column({ space: 10 }) {
      Text(`收藏夹（${this.favList.length}）`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.cc_text_title'))

      if (this.favList.length === 0) {
        Text('还没有收藏：点列表每行右侧的星标即可收藏')
          .fontSize(14)
          .fontColor($r('app.color.cc_text_muted'))
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      } else {
        List({ space: 6 }) {
          ForEach(this.favList, (catnum: number) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(this.nameMain(this.favName(catnum)))
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.cc_text_title'))
                    .maxLines(2)
                    .wordBreak(WordBreak.BREAK_WORD)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.nameParen(this.favName(catnum)).length > 0) {
                    Text(this.nameParen(this.favName(catnum)))
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.cc_text_title'))
                      .maxLines(1)
                      .minFontSize(8)
                      .maxFontSize(13)
                      .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(`NORAD ${catnum}`)
                    .fontSize(12)
                    .fontColor($r('app.color.cc_text_muted'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 直接在这里加入/移出「已选择」
                Toggle({ type: ToggleType.Switch, isOn: this.isSelectedLocal(catnum) })
                  .selectedColor($r('app.color.cc_primary'))
                  .onChange((isOn: boolean): void => {
                    if (isOn !== this.isSelectedLocal(catnum)) {
                      this.toggleSelected(catnum)
                    }
                  })

                // 收藏星标：取消后本行仍保留（只切换图标状态），关闭面板再打开才刷新列表
                SymbolGlyph(this.isFavoriteLocal(catnum) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
                  .fontSize(18)
                  .fontColor([this.isFavoriteLocal(catnum) ? $r('app.color.cc_accent_text') : $r('app.color.cc_text_muted')])
                  .padding(6)
                  .onClick((): void => {
                    Favorites.toggle(catnum)
                  })
              }
              .width('100%')
              .padding(8)
              .backgroundColor($r('app.color.cc_card'))
              .borderRadius(8)
            }
          }, (catnum: number): string => String(catnum))
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private searchSheetBuilder() {
    Column({ space: 10 }) {
      Text('搜索卫星并选择要跟踪的')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.cc_text_title'))

      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索名称或 NORAD 编号', text: this.searchQuery })
          .layoutWeight(1)
          .height(36)
          .borderRadius(8)
          .fontSize(14)
          .onChange((value: string): void => {
            this.searchQuery = value;
            this.applySearchQuery();
          })
      }
      .width('100%')

      if (this.searchResults.length === 0) {
        Text('输入关键词搜索卫星')
          .fontSize(14)
          .fontColor($r('app.color.cc_text_muted'))
          .width('100%')
          .padding({ top: 20, bottom: 20 })
          .textAlign(TextAlign.Center)
      } else {
        List({ space: 6 }) {
          ForEach(this.searchResults, (s: SatOrbitalData) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(this.nameMain(s.name))
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.cc_text_title'))
                    .maxLines(2)
                    .wordBreak(WordBreak.BREAK_WORD)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.nameParen(s.name).length > 0) {
                    Text(this.nameParen(s.name))
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.cc_text_title'))
                      .maxLines(1)
                      .minFontSize(8)
                      .maxFontSize(13)
                      .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(`NORAD ${s.catnum}`)
                    .fontSize(12)
                    .fontColor($r('app.color.cc_text_muted'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.isSelectedLocal(s.catnum) })
                  .selectedColor($r('app.color.cc_primary'))
                  .onChange((isOn: boolean): void => {
                    if (isOn !== this.isSelectedLocal(s.catnum)) {
                      this.toggleSelected(s.catnum)
                    }
                  })
              }
              .width('100%')
              .padding(8)
              .backgroundColor($r('app.color.cc_card'))
              .borderRadius(8)
            }
          }, (s: SatOrbitalData): string => {
            return String(s.catnum)
          })
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private floatingButtons() {
    Column({ space: 14 }) {
      this.floatButton($r('sys.symbol.arrow_up_to_line'), '返回顶部', 'top')
      this.floatButton($r('sys.symbol.magnifyingglass'), '搜索', 'search')
      this.floatButton($r('sys.symbol.star_fill'), '收藏夹', 'favorites')
    }
    .alignItems(HorizontalAlign.End)
    .margin({ right: 14, bottom: this.barClearance })
    .onAppear((): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
        this.btnEntered = true;
      });
    })
  }

  /** 与底部任务栏同款玻璃风格：磨砂背板 + 主题色 Symbol + 按压缩放。 */
  @Builder
  private floatButton(icon: Resource, labelTxt: string, action: string) {
    Column({ space: 3 }) {
      Column() {
        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([$r('app.color.cc_accent_text')])
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.cc_card'))
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
      .shadow({ radius: 12, color: '#26000000', offsetY: 3 })
      .opacity(0.94)
      .scale({ x: this.pressScale(`fab-${action}`), y: this.pressScale(`fab-${action}`) })
      .onTouch((event: TouchEvent): void => {
        this.onBtnTouch(`fab-${action}`, event);
      })
      .onClick((): void => {
        if (action === 'top') {
          this.backToTop()
        } else if (action === 'update') {
          this.doDownload()
        } else if (action === 'import') {
          this.doImport()
        } else if (action === 'favorites') {
          this.openFavorites()
        } else {
          this.openSearch()
        }
      })
      Text(labelTxt).fontSize(12).fontColor($r('app.color.cc_text_muted'))
    }
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private sectionHeader(title: string, count: number) {
    Row({ space: 6 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.cc_text_title'))
      Text(`${count}`)
        .fontSize(12)
        .fontColor($r('app.color.cc_text_muted'))
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 10, bottom: 6 })
    .backgroundColor($r('app.color.cc_page_bg'))
  }

  @Builder
  private satRow(item: SatOrbitalData) {
    Row({ space: 12 }) {
      Column() {
        Text(this.nameMain(item.name))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.cc_text_title'))
          // 主体字号固定；过长时换行（按词换行，中文按字）
          .maxLines(2)
          .wordBreak(WordBreak.BREAK_WORD)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.nameParen(item.name).length > 0) {
          // 括号段单独一行：若仍放不下，自动缩小字号直到完整显示
          Text(this.nameParen(item.name))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.cc_text_title'))
            .maxLines(1)
            .minFontSize(8)
            .maxFontSize(15)
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(`NORAD ${item.catnum}`)
          .fontSize(12)
          .fontColor($r('app.color.cc_text_muted'))
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.isSelectedLocal(item.catnum) })
        .selectedColor($r('app.color.cc_primary'))
        .onChange((isOn: boolean): void => {
          if (isOn !== this.isSelectedLocal(item.catnum)) {
            this.toggleSelected(item.catnum)
          }
        })

      // 收藏星标（在选择开关之后）
      SymbolGlyph(this.isFavoriteLocal(item.catnum) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
        .fontSize(18)
        .fontColor([this.isFavoriteLocal(item.catnum) ? $r('app.color.cc_accent_text') : $r('app.color.cc_text_muted')])
        .padding(6)
        .onClick((): void => {
          Favorites.toggle(item.catnum)
        })

      Row()
        .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .borderRadius(12)
      .border({ width: 1, color: $r('app.color.cc_border'), radius: 12 })
    // 共享元素转场：同一颗星在「未选择」消失、「已选择」出现时按位置插值飞行
    .geometryTransition(`sat-${item.catnum}`)
    .transition(TransitionEffect.OPACITY)
  }

  private isSelectedLocal(catnum: number): boolean {
    return this.selectedCats.indexOf(catnum) >= 0;
  }

  /** 名字中「括号之前」的主体（没有括号或括号开头则返回原名） */
  private nameMain(name: string): string {
    const i = name.indexOf('(');
    return i > 0 ? name.substring(0, i).trim() : name;
  }

  /** 名字里的括号段（含括号，一直到结尾），没有则为空串 */
  private nameParen(name: string): string {
    const i = name.indexOf('(');
    return i > 0 ? name.substring(i).trim() : '';
  }

  private isFavoriteLocal(catnum: number): boolean {
    return this.favoriteCats.indexOf(catnum) >= 0;
  }

  /** 收藏项的名称（用于收藏夹面板） */
  private favName(catnum: number): string {
    const sat = this.app.getStore().getByCatnum(catnum);
    return sat === null ? `NORAD ${catnum}` : sat.name;
  }

  private openFavorites(): void {
    // 数据在启动时已加载到内存（不重复读盘）。
    // 打开时快照一份收藏列表：面板内取消收藏只改变星标状态，行不立刻消失，
    // 避免误点后行跳走；重新打开面板时才按最新收藏集刷新。
    this.favList = Array.from(this.favoriteCats);
    this.sheetIsSearch = false;
    this.sheetVisible = true;
  }

  // ---- 悬浮按钮动画（与底栏/其他页同一套）----

  /** 入场：整组按钮从 0.86 回弹到 1；按压：当前按钮收到 0.9 再回弹。 */
  private pressScale(key: string): number {
    const base = this.btnEntered ? 1 : ENTER_SCALE;
    return this.pressedBtn === key ? base * PRESS_SCALE : base;
  }

  private onBtnTouch(key: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.getUIContext().animateTo({ duration: PRESS_IN_MS, curve: Curve.EaseOut }, (): void => {
        this.pressedBtn = key;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext().animateTo({ duration: PRESS_OUT_MS, curve: Curve.EaseOut }, (): void => {
        if (this.pressedBtn === key) {
          this.pressedBtn = '';
        }
      });
    }
  }
}