# iOS ir Android funkciju lygybes matrica

Data: 2026-07-13

## Reikalavimai

| Funkcija | iOS 26 default dialer + Tele2 recording | Tele2 VoIP endpoint + musu softphone |
|---|---|---|
| Tas pats viesas brokerio numeris | Taip, skambina ta pati SIM/eSIM | Neirodyta, turi patvirtinti Tele2 |
| Ieinantys tuo paciu numeriu | Taip, i ta pacia SIM/eSIM | Neirodyta, reikia dual-ring/SIM fallback |
| Automatinis abieju pusiu irasas | Taip, jei Tele2 planas tai patvirtina | Neirodyta tam endpointo tipui |
| Call ID, statusai, laikai, recording URL | Taip, oficialus Tele2 API/webhookai | Tiketina, bet reikia realaus piloto |
| Musu kontaktai, recent, keypad | Taip | Taip |
| Musu UI lieka per iseinanti skambuti | Apple dokumentuoja, kad lieka matomas | Taip |
| Mute, hold, DTMF, Bluetooth, end musu UI | Ne: cellular valdymo API viesai nepateikta | Taip per CallKit/LiveCommunicationKit VoIP |
| Ieinancio skambucio faktas appse | Taip per Apple history ir Tele2 webhook | Taip per VoIP push ir Tele2 webhook |
| Atsakytas skambutis atidaro leada foreground | Taip | Taip |
| App fone/locked pati issoka po skambucio | Ne: iOS foreground reikalauja naudotojo veiksmo | Ne: tas pats iOS apribojimas |
| Missed nekuria leado ir neatidaro CRM | Taip | Taip |
| Nemokama | Ne, recording yra operatoriaus paslauga | Neirodyta; tiketinas operatoriaus mokestis |

## Pasirinkimas

Produkcijos bazinis kelias yra `iOS 26 default dialer + Tele2 Mobili stotele`:
jis jau turi oficialius API irodymus svarbiausioms verslo salygoms - tam paciam
SIM numeriui, operatoriniam recording ir automatiniam Base44 importui.

Vienintelis rastas kelias pilniems skambucio valdikliams musu UI yra Tele2
`VoIP endpoint` registracija musu softphone. Viešas Tele2 portalo JavaScript
papildomai įrodo, kad portalas turi endpointų kūrimą, keitimą, registracijos
būseną, kredencialų atnaujinimą, ACL ir rodo `registrar_address`, `username` bei
`password`. Darbuotojo skambučių priėmimo forma leidžia pasirinkti kelis
endpointus, o mobilusis ryšys yra endpointas `0`, todėl platformoje numatytas
maršrutas į mobilųjį ir VoIP įrenginius.

Pilnai patikimam incoming reikalingas mūsų SIP push gateway: jis nuolat laiko
Tele2 registraciją, siunčia APNs PushKit ir perduoda SIP/RTP mūsų iOS app. Vien
tiesioginė iPhone SIP registracija neveiktų, kai iOS sustabdo programą. Gateway
gali būti atviro kodo Kamailio/Asterisk/Flexisip serveryje; telefone vis tiek
lieka viena CRM Phone programėlė.

Softphone varikliui pasirinktas `baresip` (BSD-3-Clause): jis palaiko iOS,
AudioUnit, SIP TLS, SRTP, hold, mute, DTMF ir Bluetooth garso maršrutus. PJSIP
GPL ir Linphone dviguba licencija uždaram produktui netinka be komercinės
licencijos.

Vis dar reikia Tele2 pilotu patvirtinti, kad endpointo outbound caller ID yra
darbuotojo tas pats MSISDN, incoming gali būti siunčiamas kartu į mobile ir VoIP,
o endpointo skambučiai gauna tuos pačius recording webhookus.

## Nekeičiama iOS riba

Apple leidzia programai grizti i foreground po naudotojo veiksmo: paspaudus
programeles piktograma, Universal Link arba push pranesima. Serverio webhookas,
background task ar skambucio istorijos atnaujinimas negali savavaliskai perkelti
programos i foreground. Todel fone arba uzrakintame iPhone baigto incoming
skambucio leadas gali buti pasiektas vienu paspaudimu, bet ne nuliniu paspaudimu.

Tai operacines sistemos saugumo riba, ne dialerio ar operatoriaus pasirinkimas.
Jos nepanaikina nei SIP, nei CallKit, nei LiveCommunicationKit, nei MDM.

## Irodymai, kuriu dar reikia

1. Apple Developer Team turi gauti `com.apple.developer.dialing-app` entitlement.
2. Tele2 turi aktyvuoti viena realu Mobili stotele numeri, recording ir API.
3. Reikia patikrinti caller ID, inbound, Bluetooth, recording ir webhookus realiu
   iPhone skambuciu.
4. Tele2 turi atsakyti, ar `VoIP endpoint` leidziamas musu softphone ir ar jis
   islaiko ta pati mobiluji numeri bei SIM/eSIM incoming.
5. Base44 turi igyvendinti funkcijas is
   `BASE44_TELE2_MOBILI_STOTELE_PROMPT_LT.md` ir publikuoti AASA faila.
