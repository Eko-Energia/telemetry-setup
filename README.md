# Setup telemetryczny dla samochodu Perła

Stack do zbierania i podglądu telemetrii z samochodu w czasie zbliżonym do rzeczywistego.

**Tailscale** (VPN) → **Mosquitto** (MQTT) → **Telegraf** (dekodowanie CAN) → **VictoriaMetrics** (baza) → **Grafana** (dashboardy)

---

## Spis treści

- [Architektura](#architektura)
- [Struktura repozytorium](#struktura-repozytorium)
- [Uruchamianie na serwerze](#uruchamianie-na-serwerze)
- [Format danych](#format-danych)
- [Konfiguracja na urządzeniu wysyłającym np. Raspberry Pi](#konfiguracja-na-urządzeniu-wysyłającym-np-raspberry-pi)
- [Test end-to-end](#test-end-to-end)
- [Grafana](#grafana)
- [Dane i retencja](#dane-i-retencja)
- [Aktualizacje](#aktualizacje)
- [Bezpieczeństwo](#bezpieczeństwo)
- [Rozwiązywanie problemów](#rozwiązywanie-problemów)

---

## Architektura

Cała komunikacja między samochodem a serwerem idzie przez Tailscale, więc broker nie musi być wystawiony do publicznego internetu.

Kluczowa właściwość: **utrata łącza nie powoduje utraty danych**. Lokalny Mosquitto na RPi kolejkuje wiadomości na dysku i dosyła je po wznowieniu połączenia - szczegóły w sekcji [Konfiguracja na urządzeniu wysyłającym](#konfiguracja-na-urządzeniu-wysyłającym-np-raspberry-pi).

---

## Struktura repozytorium

```
.
├── docker-compose.yml                   # cały stack serwerowy
├── config/
│   └── mosquitto.conf                   # konfiguracja brokera na serwerze
├── telegraf/
│   ├── telegraf.conf                    # MQTT in → VictoriaMetrics out
│   └── can_decode.star                  # dekodowanie payloadu CAN (Starlark)
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── victoriametrics.yml      # auto-dodanie źródła danych
│       └── dashboards/
│           ├── provider.yml             # auto-ładowanie dashboardów z tego folderu
│           └── example-can-signals.json # przykład - można usunąć
└── docs/
    └── info.md                          # notatki z pierwszej konfiguracji
```

Katalogi z danymi (`mq-data/`, `mq-log/`, `vm-data/`) tworzą się same przy pierwszym starcie i są w `.gitignore`.

---

## Uruchamianie na serwerze

1. Zainstaluj tunel Tailscale (https://tailscale.com/) i zaloguj się na odpowiednie konto (to samo co wykorzystywane w aucie).

    Adres serwera w tailnecie będzie potrzebny przy konfiguracji RPi - podejrzysz go w dashboardzie Tailscale (https://login.tailscale.com/admin/machines), przy odpowiedniej maszynie.

2. Zainstaluj Dockera:
    - Linux: https://docs.docker.com/engine/install (i pamiętaj aby wykonać to: https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user)
    - Windows/MacOS: https://www.docker.com/products/docker-desktop/

    Na Windows użyj backendu WSL2 (domyślny w Docker Desktop) - sam montuje dyski, więc nie trzeba nic konfigurować w *File sharing*.

3. Wywołaj `docker compose up` by uruchomić kontenery, gdy wszystko juz działa naciśnij `d` by zrobić detach.

Na twoim serwerze zostaną udostępnione usługi pod danymi portami:

| Port | Usługa | Do czego |
|------|--------|----------|
| `3000` | Grafana | dashboardy - wejście przez przeglądarkę |
| `8428` | VictoriaMetrics | UI do zapytań (`/vmui`), endpoint zapisu i API Prometheusa |
| `1883` | Mosquitto | broker MQTT - tu wpada bridge z samochodu |

---

## Format danych

### Wejście - MQTT

`dbc-can-bridge` publikuje JSON na topic **`messages`**. Obsługiwane są dwa kształty payloadu:

**`update`** - jedna wiadomość CAN:

```json
{
  "type": "update",
  "message_name": "BMS_Status",
  "entry": {
    "timestamp": "2026-01-12T14:23:46.123456789+01:00",
    "signals": [
      { "name": "Battery_Voltage", "value": 48.6, "unit": "V" }
    ]
  }
}
```

**`snapshot`** - mapa wielu wiadomości:

```json
{
  "type": "snapshot",
  "data": {
    "BMS_Status": {
      "timestamp": "2026-01-12T14:23:46.123456789+01:00",
      "signals": [
        { "name": "Battery_Voltage", "value": 48.6, "unit": "V" }
      ]
    }
  }
}
```

Payloady innego typu (`subscribe`, `raw`, `transmit`) są odrzucane przez [can_decode.star](telegraf/can_decode.star).

### Wyjście - metryki

Każdy sygnał staje się osobną serią czasową, ze znacznikiem czasu **z payloadu**, a nie z momentu odbioru:

```
can_signal_value{message="BMS_Status", signal="Battery_Voltage", unit="V"} 48.6
```

Czyli w Grafanie / PromQL:

```promql
can_signal_value{message="BMS_Status", signal="Battery_Voltage"}
```

Zmiana struktury payloadu po stronie samochodu wymaga zmiany w [can_decode.star](telegraf/can_decode.star) - to jedyne miejsce w stacku, które zna format danych.

---

## Konfiguracja na urządzeniu wysyłającym np. Raspberry Pi

Tryb bridge MQTT dzięki czemu w przypadku zerwania połączenia, dane są kolejkowane lokalnie, a w przypadku jego wznowienia przekazywane do kolejki na serwerze. Dane powinny być wysyłane z ustawienie QOS=1.

> Przy QoS 0 wiadomość ginie już na wejściu do lokalnego brokera i żadne buforowanie jej nie uratuje.

1. Zainstaluj Tailscale (https://tailscale.com/docs/install/linux)

2. Zainstaluj Mosquitto

```bash
sudo apt update
sudo apt install -y mosquitto mosquitto-clients
sudo systemctl enable mosquitto
```

3. Utwórz plik `/etc/mosquitto/conf.d/rpi.conf` oraz zapisz w nim:

```
# lokalny broker (urządzenia publikują tutaj)
listener 1883
allow_anonymous true

# limit kolejki: rozmiarem, nie liczbą sztuk
max_queued_messages 0                # 0 = bez limitu na sztuki
max_queued_bytes 1073741824          # 1 GB

# --- bridge do serwera, tylko wysyłka ---
connection rpi-to-serwer
address serwer:1883
topic messages out 1                 # QoS 1 = kolejkowanie niewysłanych przy zerwaniu

bridge_protocol_version mqttv50
cleansession false                   # zachowaj kolejkę bridge'a między rozłączeniami
try_private true
notifications true
restart_timeout 10
```

W `address` podmień `serwer` na nazwę MagicDNS (z Tailscale) albo adres `100.x.y.z` serwera z tailnetu.

Nie dodawaj tu opcji persystencji - bazowy `/etc/mosquitto/mosquitto.conf` z Debiana już ją zawiera, a duplikat sprawia, że Mosquitto nie wstaje (status 3).

4. Uruchom ponownie mosquitto

```bash
sudo systemctl restart mosquitto
sudo systemctl status mosquitto
```

### Co składa się na odporność na zerwanie łącza

| Ustawienie | Rola |
|------------|------|
| `topic messages out 1` | QoS 1 - niewysłane wiadomości są kolejkowane, nie porzucane |
| `cleansession false` | kolejka bridge'a przeżywa rozłączenie |
| persystencja z bazowego configu | kolejka zrzucana na dysk, przeżywa reboot RPi |
| `max_queued_messages 0` + `max_queued_bytes` | limit kolejki liczony rozmiarem (1 GB), bez limitu na sztuki |

Po stronie serwera Telegraf robi to samo w drugą stronę: `persistent_session = true` ze stałym `client_id`, więc jego restart nie gubi wiadomości zaległych w brokerze.

---

## Test end-to-end

Na **serwerze** nasłuchuj przez klienta wewnątrz kontenera brokera (dlatego `localhost` jest tu poprawny):

```bash
docker exec -it mosquitto mosquitto_sub -h localhost -t messages -v
```

Na **RPi** opublikuj z QoS 1:

```bash
mosquitto_pub -h localhost -t messages -m 'test' -q 1
```

Pojawienie się `messages test` w oknie `mosquitto_sub` oznacza, że ścieżka transportowa działa.

Żeby sprawdzić całość razem z dekodowaniem, opublikuj prawdziwy payload i zajrzyj do VictoriaMetrics - `http://<serwer>:8428/vmui`, zapytanie `can_signal_value`.

### Test buforowania

1. Serwer: `docker compose stop`
2. RPi: opublikuj kilka wiadomości z `-q 1` - lokalny broker je zakolejkuje
3. Serwer: `docker compose start`
4. Zaległe wiadomości dojdą po wznowieniu połączenia, do ~10 s (`restart_timeout`)

---

## Grafana

Wejście: `http://<serwer>:3000`

Anonimowy dostęp jest włączony w roli **Viewer** - można patrzeć na dashboardy bez logowania. Do edycji trzeba się zalogować (domyślnie `admin` / `admin`, hasło zmieniane przy pierwszym logowaniu).

Źródło danych VictoriaMetrics dodaje się samo przy pierwszym starcie.

### Dashboardy jako kod

W przypadku Grafany mozna tworzyć i eksportować dashboardy oraz zapisywać je w repozytorium (`grafana/provisioning/dashboards`) - w razie potrzeby mozna dodac inne zródła w repo np. na alerty itp.

> **Provisioning działa jednokierunkowo:** plik → Grafana. Edycja dashboardu w UI **nie** zapisuje się do repo.

Żeby zachować dashboard zrobiony w UI:

1. Otwórz dashboard → *Share* → *Export* → *Save to file* (albo *Dashboard settings* → *JSON Model*)
2. Wrzuć JSON do `grafana/provisioning/dashboards/`
3. Zacommituj

Pliki są przeładowywane co 10 s, bez restartu kontenera. Podkatalogi stają się folderami w Grafanie.

[example-can-signals.json](grafana/provisioning/dashboards/example-can-signals.json) to tylko demonstracja mechanizmu - można go skasować.

Odświeżanie dashboardów jest odblokowane do 1 s (`GF_MIN_REFRESH_INTERVAL`), a Telegraf wysyła dane co 1 s, więc podglądy na żywo mają sens.

---

## Dane i retencja

| Lokalizacja | Zawartość |
|-------------|-----------|
| `vm-data/` | baza VictoriaMetrics - **tu leży cała historia telemetrii** |
| `mq-data/` | kolejka Mosquitto (przeżywa restart) |
| `mq-log/` | logi brokera |
| wolumen `grafana-data` | użytkownicy, ustawienia i dashboardy zrobione w UI |

Retencja VictoriaMetrics to `100y`, czyli w praktyce dane nie są nigdy usuwane automatycznie. Kopię zapasową robi się przez archiwizację `vm-data/` przy zatrzymanym stacku.

Grafana trzyma dane w wolumenie nazwanym, nie w bind-mouncie - kontener działa jako uid 472 i nie miałby prawa pisać do katalogu należącego do roota. Konsekwencja: `docker compose down -v` skasuje ustawienia Grafany, samo `down` ich nie tknie.

---

## Aktualizacje

Obrazy nie aktualizują się same - świadoma decyzja, żeby nowa wersja nie wjechała w środku jazdy:

```bash
docker compose pull
docker compose up -d
```

Warto to robić między sesjami, nie w trakcie.