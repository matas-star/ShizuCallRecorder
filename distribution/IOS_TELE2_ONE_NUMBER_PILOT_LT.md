# iPhone + Tele2 vieno numerio priemimo testas

## Pries testa

1. Vienam brokerio numeriui Tele2 aktyvuoja `Mobili stotele`, automatini abieju
   krypciu recording ir API prieiga.
2. Base44 igyvendina `BASE44_TELE2_MOBILI_STOTELE_PROMPT_LT.md` kontrakta.
3. Tele2 integraciju puslapyje sukuriamas API key ir keturi webhookai:
   `CallStarted`, `CallConnected`, `CallCompleted`, `CallRecorded`.
4. Apple Developer Team gauna `Default Dialer App` entitlement. Buildas
   pasirasomas su `CRMPhoneAgent.default-dialer.entitlements` ir idiegiamas per
   TestFlight arba Ad Hoc.
5. iPhone turi iOS 26+, yra ES ir naudoja tikra brokerio Tele2 SIM/eSIM.
6. iPhone nustatymuose CRM Phone pasirenkamas numatytuoju dialeriu.

## CI be vietinio Mac

Po pakeitimu ikelimo i GitHub atidarykite `Actions > Build iOS CRM Phone > Run
workflow`. Workflow naudoja `macos-26`, Xcode 26 ir iOS 26 SDK. Zalias buildas
irodo kompiliacija, bet nepasiraso IPA. TestFlight/Ad Hoc diegimui vis tiek reikia
Apple Developer sertifikato ir provisioning profilio; juos galima valdyti per
GitHub secrets bei App Store Connect, bet pirmam pilotui saugiau naudoti Xcode
Cloud arba vienkartine nuomojama Mac aplinka.

## Testai

Kiekvienam testui uzrasykite telefono laika, brokerio numeri, kliento numeri,
Tele2 `callID`, Base44 CallSession ID ir `recordingID`.

| ID | Veiksmas | Privalomas rezultatas |
|---|---|---|
| T1 | Base44 leade spausti skambinti | Atsidaro CRM Phone, numeris perduotas teisingai, skambinama be kito dialerio |
| T2 | Atsiliepti kliento telefone ir kalbeti 20 s | Klientas mato ta pati brokerio mobiluji numeri |
| T3 | Baigti T2 is CRM Phone foreground | Automatiškai atsidaro tas pats leadas; viena CallSession ir vienas irasas |
| T4 | Klientas skambina brokerio numeriu, brokeris atsiliepia | Skamba ta pati SIM/eSIM; Base44 gauna inbound, teisinga numeri ir irasa |
| T5 | Pakartoti T4 uzrakintame iPhone | Po skambucio ateina vienas push i konkretu leada; paspaudus atsidaro leadas |
| T6 | Klientas skambina, brokeris neatsiliepia | Lead nesukuriamas, CRM neatsidaro, recording nelaukiamas |
| T7 | Brokeris skambina, klientas neatsiliepia | Lead nesukuriamas, CRM neatsidaro, recording nelaukiamas |
| T8 | T2 metu naudoti Bluetooth, speaker, mute, keypad ir baigti skambuti | Pazymeti, kurie valdikliai veikia musu UI, o kurie tik sistemos UI |
| T9 | Du kartus pakartoti ta pati Tele2 webhook payload | Lieka viena CallSession ir vienas recording |
| T10 | Isjungti app, atlikti incoming, vel atidaryti app | `syncIosCellularHistory` perduoda skambucio metaduomenis be dublikato |
| T11 | Atidaryti Base44 `/mobile/call` nuoroda Safari | Atsidaro CRM Phone per Universal Link, ne interneto puslapis |
| T12 | Patikrinti Base44 storage | Audio turi abi puses, teisinga call ID, numerius, krypti ir trukme |

## Priemimo taisykles

Pagrindini operatorini varianta galima diegti tik jei T1-T7 ir T9-T12 praeina.
T8 yra sprendimo vartas: jei brokeriui visi valdikliai privalo buti musu UI,
Tele2 turi suteikti SIP/WebRTC duomenis savo `VoIP endpoint`; tada atliekamas
atskiras CallKit softphone pilotas su tuo paciu caller ID ir SIM dual-ring.

Joks testas nelaikomas praeitu vien pagal ekrano vaizda. Reikia sutampancio
Tele2 `callID`, Base44 sesijos, recording ID ir realiai perklausyto audio.
