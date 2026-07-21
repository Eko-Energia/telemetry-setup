Masz — pełna, spójna instrukcja od nowa, z uwzględnieniem tego, co się właśnie okazało: bazowy `mosquitto.conf` na RPi (Debian) już zawiera persystencję, więc w `rpi.conf` jej **nie** dublujemy. Serwer w dwóch wariantach (Linux/Windows), RPi z bridgem, jeden topic `messages` w górę, bez hasła, kolejkowanie odporne na zerwanie łącza i reboot, limit kolejki 1 GB.

---

# SERWER — wybierz jeden wariant

```
name: ghostfolio
services:

  watchtower:
    image: containrrr/watchtower
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=21600
      - DOCKER_API_VERSION=1.54  # Matches your Engine API exactly
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
```

## Wariant LINUX (bind na `tailscale0`)

### L1. Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale status
```

### L2. Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER      # przeloguj się
```

### L3. Pliki
```bash
sudo mkdir -p /opt/mqtt/config && sudo chown -R $USER:$USER /opt/mqtt && cd /opt/mqtt
```

`/opt/mqtt/docker-compose.yml`:
```yaml
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/mosquitto/config
      - ./data:/mosquitto/data
      - ./log:/mosquitto/log
```

`/opt/mqtt/config/mosquitto.conf`:
```
listener 1883
bind_interface tailscale0
allow_anonymous true

persistence true
persistence_location /mosquitto/data/
autosave_interval 60

log_dest stdout
```
Uwaga: to obraz Dockera `eclipse-mosquitto`, którego bazowy config **nie** ma persystencji — więc tu wpisujesz ją jawnie i duplikatu nie będzie (inaczej niż na RPi z apta).

### L4. Start
```bash
docker compose up -d
docker compose logs -f mosquitto
```

---

## Wariant WINDOWS (bind na adres Tailscale)

### W1. Tailscale
Instalator z tailscale.com/download, zaloguj przez tray. Adres:
```powershell
tailscale ip -4        # zanotuj 100.x.y.z
```

### W2. Docker Desktop
Zainstaluj, potem Settings → Resources → File sharing — udostępnij dysk z projektem (np. `C:`).

### W3. Pliki
```powershell
mkdir C:\mqtt\config -Force; cd C:\mqtt
```

`C:\mqtt\docker-compose.yml`:
```yaml
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: mosquitto
    restart: unless-stopped
    ports:
      - "100.x.y.z:1883:1883"      # adres Tailscale z W1
    volumes:
      - ./config:/mosquitto/config
      - ./data:/mosquitto/data
      - ./log:/mosquitto/log
```

`C:\mqtt\config\mosquitto.conf`:
```
listener 1883
allow_anonymous true

persistence true
persistence_location /mosquitto/data/
autosave_interval 60

log_dest stdout
```

### W4. Start
```powershell
docker compose up -d
docker compose logs -f mosquitto
```

`autosave_interval 60` skraca okno utraty przy nagłej awarii do ~60 s (domyślne 1800 = pół godziny). Persystencja idzie do wolumenu `./data`, więc przeżywa też restart kontenera.

---

# RPi (Linux) — bridge z buforowaniem

`serwer` = nazwa MagicDNS albo `100.x.y.z` serwera.

### R1. Instalacja
```bash
sudo apt update
sudo apt install -y mosquitto mosquitto-clients
sudo systemctl enable mosquitto
```

### R2. Persystencja — NIE dodawaj jej do `rpi.conf`
Bazowy `/etc/mosquitto/mosquitto.conf` z Debiana **już ma** `persistence true` i `persistence_location /var/lib/mosquitto/`. Dublowanie tego w `rpi.conf` = status 3 przy starcie (właśnie na tym poległeś). Jeśli chcesz skrócić `autosave_interval` z domyślnych 1800 s, zmień to **w bazowym** pliku, nie w `rpi.conf`:
```bash
grep -n "autosave" /etc/mosquitto/mosquitto.conf
```
Jeśli zwróci `#autosave_interval 1800` — odkomentuj i zmień na `60`. Jeśli nic nie zwróci — dopisz do bazowego:
```bash
echo "autosave_interval 60" | sudo tee -a /etc/mosquitto/mosquitto.conf
```

### R3. `/etc/mosquitto/conf.d/rpi.conf` — bez persystencji
```
# lokalny broker (urządzenia w domu publikują tutaj)
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

### R4. Weryfikacja i start
Sprawdź config na pierwszym planie (pokaże błąd wprost, gdyby coś było nie tak):
```bash
sudo -u mosquitto /usr/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf -v
```
Jak zawiśnie bez błędu — `Ctrl+C`, potem:
```bash
sudo systemctl restart mosquitto
sudo systemctl status mosquitto
```

Co daje odporność na awarię, razem:
- **`topic messages out 1`** — QoS 1, niewysłane wiadomości są kolejkowane zamiast porzucane.
- **`cleansession false`** — kolejka bridge'a przeżywa rozłączenie.
- **persystencja z bazowego configu + `autosave_interval 60`** — kolejka zrzucana na dysk co ~60 s, przeżyje reboot RPi.
- **`max_queued_messages 0` + `max_queued_bytes 1073741824`** — kolejka limitowana rozmiarem (1 GB), bez limitu sztuk.

---

# Test

Na **serwerze** — przez `docker exec`, klient wewnątrz kontenera brokera, więc `localhost` poprawne:
```bash
docker exec -it mosquitto mosquitto_sub -h localhost -t messages -v
```

Na **RPi** — publikuj z **QoS 1** (inaczej ginie już na wejściu do lokalnego brokera):
```bash
mosquitto_pub -h localhost -t messages -m 'test' -q 1
```

`messages test` w oknie `docker exec` na serwerze = działa.

### Test buforowania (opcjonalny)
1. Serwer: `docker compose stop`.
2. RPi: opublikuj kilka wiadomości z `-q 1` — lokalny broker je zakolejkuje.
3. Serwer: `docker compose start`.
4. `docker exec ... mosquitto_sub` — zaległe wiadomości dojdą po wznowieniu (do ~10 s przez `restart_timeout`).

---

# Najczęstsze potknięcia

- **RPi, status 3 po dodaniu opcji** — duplikat między bazowym `mosquitto.conf` a `conf.d/rpi.conf` (najczęściej `persistence_location`). Sprawdź `grep -rn "persistence\|listener\|allow_anonymous" /etc/mosquitto/` i zostaw każdą opcję tylko w jednym pliku.
- **Wiadomości nie przetrwały testu buforowania** — publikujesz bez `-q 1` albo w `topic` masz `out 0` zamiast `out 1`.
- **Kolejka zatrzymała się szybciej niż na 1 GB** — brak `max_queued_messages 0`, wrócił domyślny limit 1000 sztuk.
- **Linux, bind odrzucany po reboocie** — `tailscale0` wstał po kontenerze; `restart: unless-stopped` to dogoni.
- **Windows, config pusty** — dysk nieudostępniony w Docker Desktop (File sharing, W2).
- **Bridge nie wstaje na RPi** — z RPi sprawdź `mosquitto_sub -h serwer -t messages -v`; nie łapie → tailnet/MagicDNS (spróbuj `100.x.y.z`), nie Mosquitto.

Kluczowa lekcja z Twojego przypadku wpleciona w R2: na RPi z apta **persystencja jest już w bazowym configu** — nie dubluj jej w `conf.d/`, bo to był ten status 3. Na serwerze w Dockerze odwrotnie: bazowy obraz jej nie ma, więc tam wpisujesz ją jawnie. Poza tym całość jak ustaliliśmy — jeden RPi, jeden topic w górę, bez hasła, kolejkowanie odporne na zerwanie łącza i reboot, limit 1 GB.