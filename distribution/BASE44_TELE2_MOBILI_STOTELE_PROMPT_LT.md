# Tekstas Base44 AI: Tele2 Mobili stotele

Integruok esama 011 Leads CRM su Tele2 Mobili stotele API. Brokeriai naudoja savo
esamus Tele2 mobiliuosius numerius ir iPhone. Nekurk naujo numerio, VoIP paskyros
ar rankinio recording/upload veiksmo.

## Secrets ir mapping

Serverio secrets saugykloje laikyk `TELE2_MOBILI_STOTELE_API_KEY`. Siusk ji tik
serverio requeste kaip `Authorization: Bearer <key>`. Niekada nedek jo i browseri.

Sukurk brokerio mappinga:

- `broker_id`
- `tele2_contact_id` (integer)
- `mobile_number_e164`
- `enabled`

## Skambinimas

Pagrindinis iOS kelias: Base44 skambinimo mygtukas atidaro universalųjį linką
`https://011-leads-copy-3090159d.base44.app/mobile/call?number=<E.164>&lead_id=<id>`.
CRM Phone, būdamas iOS 26 EU
numatytuoju dialeriu, kviečia `StartCellularConversationAction`. Taip skambutis
vyksta per brokerio tą pačią SIM/eSIM, lieka mūsų dialerio UI ir nereikia
sisteminio patvirtinimo.

Prieš skambutį CRM Phone kviečia `prepareIosCall` su:

- `broker_id`;
- `phone_number`;
- `provider=tele2_mobile_station`.

Tele2 `Dial(destination, contactID)` laikyk tik atsarginiu nuotolinio
click-to-call keliu. Jis siunčia komandą į įrenginį, todėl nėra pagrindinis kelias,
kol realaus iPhone pilotas nepatvirtino, kad išlaikomas mūsų dialerio UI.

Publikuok `https://011-leads-copy-3090159d.base44.app/.well-known/apple-app-site-association`
be redirect ir su `Content-Type: application/json`. Turinys:

```json
{
  "applinks": {
    "details": [{
      "appIDs": ["APPLE_TEAM_ID.lt.crmphone.agent"],
      "components": [{ "/": "/mobile/call", "comment": "CRM Phone call handoff" }]
    }]
  }
}
```

`APPLE_TEAM_ID` pakeisk tikru Apple Developer Team ID. Kol AASA dar neįdiegtas,
testui naudok `crmphone://call?number=<E.164>&lead_id=<id>`.

## Tele2 SIP ir PushKit

Sukurk serverio funkcija `prepareIosIncomingCall`. Ji priima `broker_id`,
`provider`, `gateway_call_id` ir `caller_number`, o grazina `{ "event_id": "..." }`.
Funkcija PRIVALO buti idempotentine pagal `gateway_call_id`: pakartotinis gateway
kvietimas turi grazinti ta pati `event_id`, o ne sukurti antra skambucio irasa ar
leada.

Pilnam mūsų skambučio UI naudok `provider=tele2_mobile_station_sip`. Sukurk
autentifikuotą `registerIosSipDevice`, kuri priima brokerio `push_token` ir
saugo tik naujausią aktyvų VoIP APNs tokeną vienam įrenginiui. Tokeno niekada
negrąžink naršyklei.

SIP push gateway nuolat registruoja Tele2 VoIP endpointą. Gavęs incoming INVITE:

1. pagal endpointą/contactID nustato brokerį;
2. normalizuoja caller į E.164;
3. sukuria laikiną call event, bet dar nekuria naujo leado;
4. į APNs VoIP push deda `provider`, `call_id`, `event_id`, `caller_number`;
5. po PushKit pažadinimo persiunčia SIP INVITE į CRM Phone;
6. galutinę answered/missed būseną ir recording koreliuoja su Tele2 webhooku.

Push turi pasiekti iPhone prieš SIP INVITE arba tuo pačiu metu. Pakartotas push
su tuo pačiu `call_id` negali parodyti antro CallKit skambučio. Jei skambutis
neatsakytas, `event_id` uždaromas kaip missed, leadas nekuriamas ir post-call
pranešimas nesiunčiamas.

Tele2 SIP password laikomas tik gateway secret saugykloje ir iOS Keychain.
Base44 lentelėje nelaikyk jo plaintext. Produkcijoje pageidautina, kad iOS gautų
trumpalaikį mūsų gateway credential, o ilgalaikis Tele2 password liktų tik
gateway serveryje.

Android esamo `crmcall://` kelio nekeisk.

## Webhookai

Sukurk viesaji `tele2MobileStationWebhook`, skirtą:

- `CallStarted`
- `CallConnected`
- `CallCompleted`
- `CallRecorded`

Webhook registruok Tele2 Mobili stotele API panelėje. Naudok tik dokumentuota
Tele2 webhook registravimo/autentifikavimo mechanizma. Eventus deduplikuok pagal
`eventType + callID + recordingID`.

Normalizuok laukus:

- `callID` -> `provider_call_id`
- `recordingID` -> `provider_recording_id`
- `caller`, `destination` -> E.164
- `direction` (`in`/`out`)
- `status`
- `callStarted`, `callConnected`, `callEnded`
- `connectionTime`
- `contactID` -> broker mapping

## Lead ir CallSession logika

- Provider yra `tele2_mobile_station`.
- CallSession unikalumas: `provider + provider_call_id`.
- Atsakymą irodo `CallConnected` arba patikimas non-null `callConnected`.
- Tik atsakytam skambuciui kurk/uzbaik CallSession.
- Kitos puses numeris inbound yra caller, outbound yra destination.
- Esama leada rask pagal E.164.
- Nezinoma leada kurk tik atsakytam skambuciui.
- Missed, rejected, busy ir failed skambutis leado nekuria, recording nelaukia ir
  post-call CRM neatidaro.
- Webhook retry negali sukurti dublikato.

## Automatinis irasas

Gavus `CallRecorded`, pagal `recordingID` kviesk `Get Call Recording by ID` arba
naudok patikima webhook `recordingURL`. Serverio puseje nedelsiant atsisiusk faila
ir issaugok Base44 storage. Prisek prie CallSession pagal `callID`.

Iraso unikalumas: `provider + recordingID`. Jei CallSession dar nesukurta, naudok
ribota exponential retry. Telefone nerodyk Record, Stop recording ar Upload
mygtuku.

## Post-call

Jei musu iOS/default dialer foreground, po atsakyto skambucio atidaryk konkretu
leada. Jei skambutis baigtas background arba lock screen, Base44 siuncia viena
push su konkretaus leado Universal Link. Missed skambuciui push nesiusk.

Sukurk `syncIosCellularHistory` autentifikuotą funkciją. Ji priima
`provider=ios_livecommunicationkit` ir masyvą su `id`, `phone_number`,
`direction`, `status`, `started_at`, `duration_seconds`. Deduplikuok pagal
`broker_id + provider + id`. Šis kanalas yra iPhone matytų įeinančių ir išeinančių
skambučių kontrolinis šaltinis; Tele2 `callID` ir recording lieka autoritetingi.
Koreliuok pagal brokerį, normalizuotą kitos šalies numerį, kryptį ir artimiausią
pradžios laiką. Nesukurk leado vien iš iOS istorijos, jei trukmė 0 arba statusas
reiškia missed/rejected/failed.

`resolveIosPostCall` visada grąžina:

- `terminal`: ar skambutis jau galutinai užbaigtas;
- `answered`: ar buvo sujungtas;
- `should_open`: tik užbaigtam atsakytam skambučiui;
- `lead_url`: tik kai `should_open=true`.

Missed/rejected/failed atsakymas: `terminal=true`, `answered=false`,
`should_open=false`, `lead_url=null`.

## Priemimo salygos

1. Base44 vienas paspaudimas inicijuoja skambuti brokerio iPhone.
2. Gavejas mato brokerio ta pati Tele2 mobiluji numeri.
3. Klientui skambinant tuo numeriu suskamba ta pati iPhone SIM/eSIM.
4. Answered incoming ir outgoing sukuria po viena CallSession.
5. Recording automatiskai atsiranda prie teisingos sesijos.
6. Missed/rejected leado nekuria ir CRM neatidaro.
7. Pakartoti webhookai nesukuria dublikatu.
8. API key nepatenka i klientini koda ar logus.
9. Android dabartinis veikimas lieka nepakeistas.
