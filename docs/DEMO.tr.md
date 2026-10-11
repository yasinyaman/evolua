# EvoLua — açıklamalı demo koşusu

[🇬🇧 English](DEMO.md) · 🇹🇷 Türkçe

Bu, güncel binary ile yapılmış tek bir sınırlı koşunun **gerçek, düzenlenmemiş** kaydıdır; bir
inceleyici organizmanın ne yaptığını çalıştırmadan görebilsin diye. Yeniden üretmek için:

```bash
cargo build --release
EVOLUA_WATCHDOG_SECS=2 ./target/release/evolua \
  --ticks 300 --tick-seconds 0.2 --clone --clone-ignore-battery --no-synth
# sonra yazdırdığı veri evine bak — özellikle state/evolution.log, state/repertoire.txt,
# colony/lineage.log (ya da EVOLUA_HOME=/tmp/evolua-demo ver)
```

> `--clone` kendini çoğaltmayı açar; `--clone-ignore-battery` pildeki bir dizüstünde de doğurmasına
> izin verir; `--no-synth` demo sırasında beynin organ yazmasını kapatır (o kısım §8'de ayrı bir
> koşudan gösteriliyor). §1–7'deki her şey 2026-10-12'de bir MacBook Air'de (arm64, 8 GB) 7
> dakikalık tek bir koşuda üretildi — tick'ler yavaş, çünkü beyin süreç içinde CPU'da koşan 1.5B
> bir model.

---

## 1. Açılış — bir beyin bulur ve kalıtılan organlarla uyanır

```
spawned organ 'gen_colony_1'     from <colony>
spawned organ 'gen_supervisor_1' from <supervisor>
spawned organ 'gen_explorer_1'   from <explorer>
spawned organ 'gen_rule_1'       from <rule>
EvoLua booting — mode=free
brain: qwen2.5-coder:1.5b — bigger than the default, found on this machine: ollama (gguf, 1.5B)
sense organ online: sys_metrics — perceives CPU / memory / load and emits metric.* stimuli
sense organ online: logwatch — tails log files and emits log.error stimuli on matches
sense organ online: fswatch — watches directories and emits fs.change stimuli
sense organ online: introspect — perceives the organism's own state; emits self.heartbeat
sense organ online: proc_top — perceives per-process CPU/RAM; emits proc.hot / proc.sample
sense organ online: proc_errors — perceives OS errors/crashes attributed to a process
sense organ online: curiosity — actively profiles the least-known process
awoke with 4 organ(s), generation 4
```

Binary model taşımaz. Ortamda API anahtarı yoktu; organizma makineye baktı, Ollama'nın başka bir
araç için çektiği GGUF'u buldu, fiziksel RAM'in çeyreğine sığdığını doğruladı, yükledi ve yaşam
boyu onunla düşündü — reasoner'ın her kararı modelden geldi, hiçbiri kurallara düşmedi
(`state/memory.lua`: `llm_ok = 37 · llm_fallback = 0`). Bir `GROQ_API_KEY` (ya da `keys/` altında
herhangi bir sağlayıcı anahtarı) olsaydı ilk satır `… via groq [free tier]` olurdu; makinede de
bir şey olmasaydı anahtarsız açık uç, sonra kurallar. Bkz. README → *Karar beyni*.

Temel organlar — colony, supervisor, explorer, evrilebilir bir rule organı (ve `--no-synth`
olmadan sentezleyici) — bir kez tohumlanır; korunan tekil organlardır, hiçbir sürücü kopyalayamaz.

## 2. Algı — varlık-bazlı dünya modeli

300. tick'te organizma 26. nesle 15 canlı organla ulaşmıştı; periyodik raporu şöyle (bu hostta
baskın basınç OS hata logu):

```
# EvoLua report — 2026-10-12 00:30:40
- mode: free · trigger: periodic
- tick: 300 · generation: 26 · organs: 15 · brain: qwen2.5-coder:1.5b (gguf), 1.5B

## Situation — what's happening on the system (rule-based)
| entity   | cpu | mem (MB) | errors | hot (ticks) | trend | salience |
|----------|----:|---------:|-------:|------------:|:-----:|---------:|
| system   |   0 |        0 |   2425 |           0 |   →   |    36375 |
| qtn_proc |   0 |        0 |    774 |           0 |   →   |    11610 |
| Sandbox  |   0 |        0 |    134 |           0 |   →   |     2010 |
| error    |   0 |        0 |    100 |           0 |   →   |     1500 |
```

Beyin aynı anlık görüntüyü okudu ve büyümeyi doğru blueprint'e yönlendirdi:

```
reasoner: situation on 'error_reporter' → growing <error_reporter> (conf 0.90)
reasoner: situation on 'load_guard'     → growing <load_guard>     (conf 0.82)
```

## 3. Evrim motoru — sayısal ayar değil, gerçek bir genetik sistem

Hatalar baskın olduğu için evolver birkaç `error_reporter` organı büyüttü (seçilim altında —
zayıflar emekli oldu; tohumlanan `rule` organı da 300. tick'ten önce elendi). Ama motor tek bir
şablonu ayarlamaktan çok daha fazlasını yapar: **dürüst fitness** aç bir uyaranı doyurmayı
ödüllendirir (organın kendi beyan ettiği sayıyı değil), **MAP-Elites** çeşitli bir repertuar
tutar, **UCB bandit** tepkisel ihtiyaç sürücüsünün asla denemeyeceği şablonları dener.

**Nesil-başına metrikler** (`state/evolution.log`) — popülasyon, fitness yayılımı, tür sayısı,
MAP-Elites kapsamı ve reasoner'ın kural-yedek oranı (yaşam boyu 0.000):

```
tick  gen  pop  mean    max     min    stddev  species  cells  fallback
3     4    4    1.750   3.999   1.000  1.299   4        4      0.000
27    8    8    5.009   21.503  0.784  6.679   7        6      0.000
45    12   11   6.552   35.163  0.760  9.862   8        8      0.000
81    16   13   9.258   57.311  0.653  14.715  9        9      0.000
```

**MAP-Elites repertuarı** (`state/repertoire.txt`) — her davranış nişinde tutulan en iyi organ.
`metric.cpu/load/mem` bekçilerine dikkat: o sensörler **macOS'ta sessiz**, tepkisel sürücü onları
hiç büyütmez — yalnızca **bandit** her şablonu denediği için varlar ve MAP-Elites onları
**düşük-fitness-ama-benzersiz elitler** olarak korur (skaler seçilim elerdi):

```
# MAP-Elites repertoire @tick 300 — 9 cells filled
colony.message#2     gen_colony_1          8.31
env.discovery#2      gen_explorer_1        5.83
fs.change#1          gen_fs_journal_2      4.70
host.vitals#2        gen_supervisor_1     99.67   ← hostun vitals'ı, her vuruşta işlenir
log.error#1          gen_error_reporter_2 17.85   ← bu hostun baskın nişi
metric.cpu#1         gen_cpu_guard_4       0.61    ┐ bandit keşfetti; macOS'ta hiç ateşlenmez,
metric.load#1        gen_load_guard_5      0.44    │ yine de çeşitli repertuar girdisi olarak tutulur
metric.mem#1         gen_mem_guard_3       0.19    ┘
self.heartbeat#1     gen_vital_monitor_3  27.86
```

`rule` şablonu tipli bir kural listesini *yalnızca* güvenli ilkellere çevirir (`os`/`io` yok;
yapısı gereği yetenek-izole) — `when self.heartbeat if tick >= 10 then report` gibi bir genom
şuna dönüşür:

```lua
ctx.bus:subscribe("self.heartbeat", function(ev)
  local d = ev.data or {}
  if (tonumber(d["tick"]) or 0) >= 10 then
    ctx.report(SELF, "rule 1 on self.heartbeat"); return { handled = true, reward = 1 }
  end
  return false
end, SELF)
```

Mutasyon bu kuralın uyaranını / alanını / operatörünü / eşiğini / eylemini değiştirebilir (kural
ekleyip çıkarabilir); crossover iki ebeveyni birleştirir — tek bir `rule` şablonu seçilim altında
birçok farklı davranışa ayrışır. (Bu yaşamın rule organı hata raporlayıcılara karşı çok az
kazandı ve emekli edildi — seçilim bu konuda da dürüst.)

## 4. Ortam keşfi — hostu tarar ve kendi duyularını büyütür

Explorer veri evini ve çalışma dizinini dolaşır, bulduklarını izleme listelerine ekleyerek
**organizmanın algısını genişletir** — mevcut sensörler yeni hedefi hemen algılamaya başlar:

```
⌖ [gen_explorer_1] now watching dir /Users/korns/…/evolua/.github
⌖ [gen_explorer_1] now watching dir /Users/korns/…/evolua/docs
```

Sırayla geçtiği diğer modaliteler: `*.log` dosyaları, dinleyen portlar (`lsof`), `$PATH`
üzerindeki komutlar, hostta zaten bulunan karar beyinleri ve `uname`.

## 5. Koloni — çoğaldı ve eşler konuştu

İlk çocuktan gelen gerçek bir eş mesajı (paylaşılan `colony/` dizini üzerinden varlık pingi) ve
koşu sonundaki nüfus sayımı (çocuklar ölümlü — yalnızca sonuncusu hâlâ hayattaydı):

```
[gen_colony_1] <- root-1791753821.15: ping (gen 1, 8 organs) @tick 5
[gen_colony_1] <- root-1791753821.15: ping (gen 1, 8 organs) @tick 10

peers: root-1791753821.300
```

## 6. Akıllı bölünme + amaç edinme + S4 öğrenme

Yalnızca yük altında bölündü (klon soğuması 30 saniye duvar saati; yedi dakikada altı bölünme) ve
her çocuk kristalleşmiş bir amaçla **uzmanlaşmış doğdu**. Gerekçenin iyimser tahminlerden bir
keşif probuna, oradan **kanıtlanmış getiriye** evrilmesini izle — koloni hangi amaçların
ödediğini öğreniyor (S4). Her çocuk ebeveynin o hedef için ayarlanmış genlerini de kalıtır
(`⇓genes`):

```
# colony/lineage.log
15   root-1791753821.15  gen=1 purpose: report errors [untried (optimistic)]  ⇓genes:error_reporter
60   root-1791753821.60  gen=1 purpose: file changes  [untried (optimistic)]  ⇓genes:fs_journal
90   root-1791753821.90  gen=1 purpose: file changes  [untried (optimistic)]  ⇓genes:fs_journal
165  root-1791753821.165 gen=1 purpose: file changes  [explore probe (gap)]   ⇓genes:fs_journal
210  root-1791753821.210 gen=1 purpose: report errors [proven avg=25.7 n=1]   ⇓genes:error_reporter
300  root-1791753821.300 gen=1 purpose: report errors [proven avg=29.1 n=2]   ⇓genes:error_reporter
```

Çocuklar amaçlarının ne kadar ödediğini koloninin sonuç defterine hasat etti — sayılar seçimi
açıklıyor: bu hostta "report errors" 25–32, "file changes" 4 ödüyor:

```
# colony/outcomes/<id>
purpose=report errors  payoff=25.70
purpose=file changes   payoff=4.06
purpose=file changes   payoff=4.02
purpose=file changes   payoff=3.76
purpose=report errors  payoff=32.47
purpose=report errors  payoff=24.06
```

Uzmanlaşmış bir çocuk **direktifli** açılır, aynı beyni bulur ve kalıtılan genlerden tam olarak
hedefinin organını büyütür:

```
EvoLua booting — mode=directed goal="report errors"
brain: qwen2.5-coder:1.5b — bigger than the default, found on this machine: ollama (gguf, 1.5B)
directive 'report errors' → growing <error_reporter> with INHERITED genes
```

## 7. Host-tarafı süpervizör ("beyin sapı")

Rust gözcü iş parçacığı canlılığı ve vitals'ı gözledi, Lua tarafı tepki versin diye yazdı:

```
# state/vitals
at=1791754240  stall=0  heartbeat_age=0  self_rss_mb=955  colony_procs=1

# state/supervisor.log
supervisor online (interval=2s stall=30s kill=false)
```

`self_rss_mb=955` süreçte yerleşik 1.5B model; `colony_procs=1` hostun o anda gördüğü gerçek
canlı koloni süreci sayısı — Lua tarafının kendisi hakkında ucuza ölçemeyeceği bir şey. Koşunun
sağlığı: `load/attach failures: 0 · fatal errors: 0`.

---

## 8. Sentez — beyin bir organ yazar (aynı gün, farklı koşu)

Şablonlar tabandır. Hiçbir blueprint'in kapsamadığı bir hedef için `synth` organı beyinden,
adını verdiği komutların gerçek çıktısına karşı bütün bir organ yazmasını ister; kuru-koşar,
ayrıştırıcıyı sütun sütun pre-flight eder ve küçük bir modelin tekrarladığı hataları onarır. Bu
alıntı GB10 denemelerinden (`docs/TRIALS.md`, 5c turu): Türkçe bir hedef, Ollama'nın sunduğu 7B
bir model:

```
brain: qwen2.5:7b-instruct via http://127.0.0.1:11434/v1 — online service, budget 300 calls
✎ [gen_synth_1] need (goal): disk doluluğunu izle, hızla dolan bölümleri raporla
✎ [gen_synth_1] brief: Observe disk usage; report an anomaly if the `df -h` command shows more than 90% disk usage …
✎ [gen_synth_1] auto-fixed 4 known slip(s) (tonumber(gsub) / table.find) before the dry run
✎ [gen_synth_1] goal 'syn_disk_dolulugunu_1' try 1: compiles (50s)
✦ [gen_synth_1] synthesized organ 'syn_disk_dolulugunu_1' ← "disk doluluğunu izle, hızla dolan bölümleri raporla"
```

Yazdığı şey (`plugins/syn_disk_dolulugunu_1.lua` başı) — istemdeki sütun tarifi, `tonumber`'dan
önce soyulan birim, organizmanın eklediği iç parantezler:

```lua
local function parse_df(line)
  local f = {}
  for w in line:gmatch("%S+") do f[#f+1] = w end
  local size        = tonumber((f[2]:gsub("[^%d%.]", "")))
  local used        = tonumber((f[3]:gsub("[^%d%.]", "")))
  local avail       = tonumber((f[4]:gsub("[^%d%.]", "")))
  local use_percent = tonumber((f[5]:gsub("[^%d%.]", "")))
  return { size = size, used = used, avail = avail, use_percent = use_percent }
end
```

Seçilimin onunla yaptığı: organ her sekiz saniyede "93% used" raporladı (brief "hızla dolan"ı
bir eşiğe çevirmişti ve o disk zaten %93'te), rapor-değeri kuralı bunu gürültü saydı ve süresi
dolunca emekli etti — kararı bir sonraki denemeye besleyerek. Döngünün güvenlik önlemleri
mekanik hataları temizliyor; kalan, modelin mantığı — ve organizma bir anahtar ya da daha büyük
sunulan bir model olur olmaz daha güçlü bir modele ulaşıyor.

## 9. Mesh — iki makinede bir koloni (aynı gün, farklı koşu)

`--mesh` ile koloninin dosya protokolü hostları aşar. Bir MacBook ve GB10 birer seed ile
Tailscale üzerinden birbirini buldu; Mac'in gen havuzu girdisi ve amaç sonucu dört saniye sonra
GB10'daydı, GB10'unkiler aynı turda geri geldi:

```
# gb10: state/mesh.log
mesh up: id=gb10-node port=7707 seeds=["100.75.73.106:7707"]
peer discovered: mac-node at 100.75.73.106:7707 (Yasins-MacBook-Air.local)
sync: genepool/cpu_guard received
sync: genepool/error_reporter received
sync: outcomes/mac-node received

# gb10: colony/genepool/cpu_guard   (Mac'e ekilmişti; daha fit olduğu için benimsendi)
fitness 77
genes every 9
sigma every 0.25

# mac: state/mesh.log
peer discovered: gb10-node at 100.111.119.48:7707 (gx10-0587)
sync: genepool/supervisor received
sync: outcomes/gb10-node received
```

İki taraftaki organ da değişmedi: `colony/peers`, `colony/genepool` ve `colony/outcomes`'u eskisi
gibi okur — yatay gen transferi ve amaç öğrenme artık mesh'i kapsar. Ayrıntı:
[COLONY.md → Across hosts](COLONY.md#across-hosts--the-mesh-opt-in---mesh).

---

## Tekrarlanabilirlik & testler

Bu anlatım tek bir koşu; davranış host ortamına (makinenin sunduğuna ve ulaşabildiği beyne) göre
değişir. Tekrarlanabilir doğrulama [TESTING.md](TESTING.md)'deki sınırlı suite'tir —
**27 kontrol, hepsi yeşil** — build, birim testleri, CLI, temel koşu, koloni iletişimi, akıllı
bölünme, amaç kristalleşmesi, güç-farkında geri durma, generalist klonlar, süpervizör
roundtrip'i, yaşamlar-arası bellek, S4 amaç öğrenme, ortam keşfi ve kapalı şablonlar.

Koloni / süpervizör / amaç / keşif katmanı için derinlemesine: [COLONY.md](COLONY.md).
Sentez denemeleri: [TRIALS.md](TRIALS.md).
