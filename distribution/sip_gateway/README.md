# CRM Phone SIP Push Gateway

> Pilot limitation: the current iOS Baresip build does not bundle OpenSSL. Use
> UDP only inside a controlled pilot network. Production rollout requires SIP
> TLS/SRTP support and must not expose unencrypted SIP credentials or media to
> the public internet.

Šis servisas uždengia iOS apribojimą, dėl kurio SIP registracija negali nuolat
veikti sustabdytoje programėlėje.

## Srautas

1. Asterisk registruojasi į brokerio Tele2 Mobili stotelė VoIP endpointą.
2. Tele2 portale darbuotojo `Receiving calls` maršrute pasirenkami `Mobile` ir
   Asterisk VoIP endpointas.
3. Incoming SIP INVITE paleidžia `notify_gateway.py`.
4. Gateway sukuria laikiną Base44 įvykį ir siunčia APNs `voip` push.
5. CRM Phone pabunda, parodo CallKit ir registruojasi į Asterisk.
6. Asterisk perduoda INVITE programėlei; SIM šaka išlieka Tele2 pusėje.
7. Outgoing iš programėlės keliauja per Asterisk į Tele2 su brokerio MSISDN.
8. Tele2 webhookai galutinai pateikia answered/missed, `callID` ir recording.

## Paleidimas

```bash
docker build -t crm-phone-sip-gateway .
docker run --rm -p 8080:8080 --env-file .env -v gateway-data:/data crm-phone-sip-gateway
```

Asterisk šablonuose pakeiskite visas didžiosiomis raidėmis pažymėtas reikšmes.
Tele2 kredencialai turi likti tik Asterisk secrets faile. `broker-device`
password yra atskiras atsitiktinis gateway credential, kurį gauna iPhone.

`registerIosSipDevice` Base44 funkcija turi persiųsti tokeną į `/v1/devices` su
gateway vidiniu Bearer secret. Viešos prieigos prie `/v1/devices` ir
`/v1/incoming` neturi būti; rekomenduojamas privatus tinklas arba reverse proxy
su IP allowlist ir TLS.

## Būtinas Tele2 pilotas

Prieš produkciją patvirtinkite tikrą registrar transportą, kodekus, signaling IP
adresus, leidžiamą caller ID ir ar VoIP endpointo šaka gauna operatorinį
recording. Šablone sąmoningai neįrašyti išgalvoti Tele2 serverio parametrai.
