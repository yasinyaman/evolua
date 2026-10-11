# EvoLua — açıklamalı demo koşusu

[🇬🇧 English](DEMO.md) · 🇹🇷 Türkçe

Bu, tek bir sınırlı koşunun **gerçek, düzenlenmemiş** çıktısıdır — böylece inceleyen biri
çalıştırmadan organizmanın ne yaptığını görebilir. Tekrarlamak için:

```bash
cargo build --release
EVOLUA_WATCHDOG_SECS=2 ./target/release/evolua \
  --ticks 160 --tick-seconds 0.2 --clone --clone-ignore-battery
# sonra veri evini incele — özellikle state/evolution.log + state/repertoire.txt
# (ya da EVOLUA_HOME=/tmp/evolua-demo ver)
```

> `--clone` kendini çoğaltmayı açar; `--clone-ignore-battery` pildeki bir dizüstünde de
> doğurmasına izin verir. Aşağıdaki her şey macOS'ta (arm64) tek bir ~32 saniyelik koşunun ürünüdür.

---

## 1. Boot — kalıtsal organlarla uyanır

```
EvoLua booting — mode=free
sense organ online: sys_metrics — perceives CPU / memory / load and emits metric.* stimuli
sense organ online: logwatch — tails log files and emits log.error stimuli on matches
sense organ online: fswatch — watches directories and emits fs.change stimuli
sense organ online: introspect — perceives the organism's own state; emits self.heartbeat
sense organ online: proc_top — perceives per-process CPU/RAM; emits proc.hot / proc.sample
sense organ online: proc_errors — perceives OS errors/crashes attributed to a process
sense organ online: curiosity — actively profiles the least-known process
awoke with 3 organ(s), generation 3
```

Temel organlar — colony, supervisor, explorer, evrilebilir bir rule organı ve sentezleyici — otomatik
tohumlanır (çekirdek değişikliği yok — `templates.lua`'daki genom blueprint'leri):

```
spawned organ 'gen_colony_1'     from <colony>
spawned organ 'gen_explorer_1'   from <explorer>
spawned organ 'gen_supervisor_1' from <supervisor>
spawned organ 'gen_supervisor_2' from <supervisor>   ← kopyalar: hata, aşağıdaki nota bak
spawned organ 'gen_supervisor_3' from <supervisor>
```

> Bu kayıt, korumalı organların tekil hale gelmesinden öncedir. Fazladan iki süpervizör, kendi
> yaydığı `host.vitals` uyaranını işleyerek liderlik tablosunun tepesine çıkan bir organın
> mutasyon kopyalarıydı. Güncel bir koşu tam bir colony, explorer, supervisor ve synth tohumlar; bus da
> bir organa kendi yaydığı uyarandan kredi vermez.

## 2. Algı — varlık-bazlı dünya modeli

160. tick'te 9. nesle / 9 organa ulaştı ve şöyle durum raporları yazdı (bu host'ta baskın
baskı OS hata loglarıydı):

```
# EvoLua report — 2026-06-21 12:40:13
- mode: free · tick: 160 · generation: 9 · organs: 9

## Situation — what's happening on the system (rule-based)
| entity   | cpu | mem (MB) | errors | hot (ticks) | trend | salience |
|----------|----:|---------:|-------:|------------:|:-----:|---------:|
| system   |   0 |        0 |    779 |           0 |   →   |    11685 |
| qtn_proc |   0 |        0 |    404 |           0 |   →   |     6060 |
| error    |   0 |        0 |     36 |           0 |   →   |      540 |
| Sandbox  |   0 |        0 |     29 |           0 |   →   |      435 |
```

## 3. Evrim motoru — sayısal ayar değil, gerçek bir genetik sistem

Hatalar baskın olduğu için evolver birkaç `error_reporter` organı büyüttü (seçilim altında —
zayıflar emekliye ayrıldı). Ama motor tek şablonu ayarlamaktan fazlasını yapar: **dürüst
fitness** aç bir uyaranı doldurmayı ödüllendirir (organın beyan ettiği sayıyı değil),
**MAP-Elites** çeşitli bir repertuar tutar, ve bir **UCB bandit** reaktif ihtiyaç-sürücüsünün
asla denemeyeceği şablonları proaktif dener.

**Jenerasyon başı metrikler** (`state/evolution.log`) — popülasyon, fitness dağılımı, tür
sayısı, MAP-Elites kapsamı — repertuar zamanla dolarken:

```
tick  gen  pop  mean     max      min    stddev  species  cells
3     4    4    1.750    4.000    1.000  1.299   4        4
39    12   12   21.895   217.063  0.737  58.931  6        6
93    18   17   15.166   142.496  0.833  32.251  9        8
```

**MAP-Elites repertuarı** (`state/repertoire.txt`) — her davranış nişi için tutulan en iyi
organ. `metric.cpu/load/mem` guard'larına dikkat: bu sensörler **macOS'ta sessiz**, reaktif yol
onları asla büyütmez — yalnız **bandit** her şablonu bir kez denediği için varlar ve MAP-Elites
onları **düşük-fitness ama benzersiz elit** olarak korur (skaler seçilim onları elerdi):

```
# MAP-Elites repertoire — 9 cells filled
colony.message#2     gen_colony_1          2.43
env.discovery#2      gen_explorer_1        4.97
fs.change#1          gen_fs_journal_2      5.79
host.vitals#2        gen_supervisor_1     14.55
log.error#1          gen_error_reporter_1 134.77   ← bu host'ta baskın niş
metric.cpu#1         gen_cpu_guard_1       0.53    ┐ bandit keşfetti; macOS'ta hiç ateşlemez,
metric.load#1        gen_load_guard_1      0.89    │ yine de çeşitlilik repertuarında tutulur
metric.mem#1         gen_mem_guard_1       0.60    ┘
self.heartbeat#1     gen_rule_2           12.48
```

**Evrilen bir rule-DSL organı** — genomu tipli kural listesi, *yalnız* güvenli primitiflere
render edilir (`os`/`io` yok; yapısal capability-isolation):

```lua
ctx.bus:subscribe("self.heartbeat", function(ev)
  local d = ev.data or {}
  if (tonumber(d["tick"]) or 0) >= 10 then
    ctx.report(SELF, "rule 1 on self.heartbeat"); return { handled = true, reward = 1 }
  end
  return false
end, SELF)
```

Mutasyon bu kuralın stimulus / field / operatör / eşik / aksiyonunu değiştirebilir (kural
ekleyip silebilir); crossover iki ebeveyni birleştirir — böylece tek bir `rule` şablonu seçilim
altında birçok ayrı davranışa farklılaşır.

## 4. Ortam keşfi — host'u tarar ve kendi duyularını büyütür

```
discovered dir:  /Users/korns/Documents/GitHub/evolua/models
discovered port: 6 listeners (ControlCe,Code H,zed)
discovered sys:  Darwin 25.5.0 arm64
discovered tool: 2089 commands on PATH; notable: git,docker,kubectl,python3,node,
                 lua,cargo,rustc,gcc,clang,go,ruby,java,make,cmake,curl,wget,ssh,jq,sqlite3
```

Sonra **kendi algısını genişletti** — bulduklarını izleme listelerine ekleyip mevcut
sensörlerin onları algılamaya başlamasını sağladı:

```
now watching dir /Users/korns/Documents/GitHub/evolua/plugins
now tailing log /Users/korns/Documents/GitHub/evolua/state/evolua.log
```

## 5. Koloni — çoğaldı ve eşler konuştu

Canlı üyeler ve gerçek bir eş mesajı (paylaşılan `colony/` dizini üzerinden varlık ping'i):

```
peers: root-1782034428  root-1782034428.135  root-1782034428.75
MSG from root-1782034366.90: ping (gen 1, 5 organs) @tick 5
```

## 6. Akıllı bölünme + amaç edinme + S4 öğrenmesi

Yalnız yük altında bölündü ve her çocuk kristalize bir amaca göre **uzman doğdu**. Gerekçenin
bir tahminden **kanıtlanmış ödüle** evrildiğine dikkat — koloni hangi amacın ödül getirdiğini
öğreniyor (S4):

```
splitting under load [needs=1 hot=4] -> ...135 (gen 1) · purpose: report errors [untried (optimistic)]
splitting under load [needs=1 hot=8] -> ...75  (gen 1) · purpose: report errors [proven avg=617.9 n=1]
splitting under load [needs=1 hot=8] -> ...135 (gen 1) · purpose: report errors [proven avg=312.4 n=2]
```

Çocuklar amaçlarının ne kadar ödül getirdiğini koloninin sonuç defterine hasat etti:

```
purpose=report errors payoff=617.93 gen=1
purpose=report errors payoff=73.47  gen=1
purpose=report errors payoff=6.92   gen=1
```

Uzman bir çocuk **directed** açılır ve tam amacının organını büyütür:

```
EvoLua booting — mode=directed goal="report errors"
directive 'report errors' → growing <error_reporter>
```

## 7. Host-tarafı süpervizör ("beyin sapı")

Rust gözcü thread'i canlılığı + vital'leri gözledi ve Lua tarafının tepki vermesi için yazdı:

```
# state/vitals
stall=0   heartbeat_age=0   self_rss_mb=4   colony_procs=7

# state/supervisor.log
supervisor online (interval=2s stall=30s kill=false)
```

`colony_procs=7`, host'un o anda gördüğü canlı koloni süreçlerinin gerçek sayısı — Lua
tarafının kendisi hakkında ucuza ölçemeyeceği bir şey.

## 8. Sağlık

```
load/attach failures: 0   ·   fatal errors: 0
```

---

## Tekrarlanabilirlik & testler

Bu anlatı tek bir koşu; davranış host ortamına göre değişir (makinenin sunduğu her şeye tepki
verir). Tekrarlanabilir doğrulama, [TESTING.md](TESTING.md)'deki sınırlı suite'tir —
**27 kontrol, hepsi yeşil** — build, temel koşu, koloni iletişimi, akıllı bölünme, amaç
kristalleşmesi, güç-farkında geri durma, generalist klonlar, süpervizör roundtrip'i,
yaşamlar-arası bellek, S4 amaç-öğrenme ve ortam keşfini kapsar.

Koloni / süpervizör / amaç / keşif katmanının derinlemesine anlatımı: [COLONY.md](COLONY.md).
