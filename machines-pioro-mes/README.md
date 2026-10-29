# Machines Pióro · MES

Aplikacja hali produkcyjnej: piła, tokarnia, rysunki PDF, magazyn części gotowych, materiałów i użytecznych resztek. Cała aplikacja znajduje się w **`index.html`**. Pozostałe pliki służą wdrożeniu, testom i konfiguracji bazy.

## Uruchomienie od razu

Otwórz `index.html` w aktualnej przeglądarce. Aplikacja uruchamia dane demonstracyjne, zlecenia Machines Pióro oraz rysunki wałka i tulei. Zmiany są zapisywane w `localStorage` tego komputera i profilu przeglądarki. Do przenoszenia bazy służy eksport/import JSON.

Do pobrania Tailwind, Lucide i PDF.js z CDN potrzebny jest internet. Interfejs ma własne style, a rysunki demonstracyjne są generowane lokalnie na Canvasie. Pierwsze otwarcie bez internetu nie zapewnia obsługi własnych PDF. Tryb `file://` jest przydatny do demonstracji; na hali używaj adresu HTTPS z Cloudflare, ponieważ zachowanie pamięci przeglądarki dla lokalnych plików zależy od przeglądarki.

Wersja demonstracyjna nie zawiera danych rzeczywistych ani dostępu do firmowych kont. Samo otwarcie aplikacji nie wysyła danych do Supabase. Zapis w chmurze wymaga skonfigurowania projektu, logowania i świadomego przesłania bazy.

## Zasada pracy

- **Piła:** detale z aktywnych zleceń są grupowane po materiale i średnicy. Można rejestrować ucięte sztuki, czas, zużycie materiału oraz resztki.
- **Tokarnia:** kolejka zawiera ucięte detale. Zakończenie z nadwyżką aktualizuje jednocześnie zlecenie i magazyn części gotowych.
- **Magazyn części:** zapas dopasowywany jest po numerze detalu; pobranie zmniejsza stan i zapotrzebowanie zlecenia.
- **Magazyn materiału:** szybkie korekty metrów, minima oraz osobna ewidencja resztek. Pobranie resztki nie odejmuje ponownie pełnej sztangi.
- **Biuro:** postępy maszyn, dodawanie zleceń, szablony i rysunki.
- **PDF:** własne pliki są renderowane przez PDF.js, a pinezki przechowują stronę i współrzędne względne. Wykrywanie części analizuje warstwę tekstową i przedstawia kandydatów do sprawdzenia. To nie jest OCR: skan bez warstwy tekstowej wymaga ręcznego dodania części.

Przełącznik stanowiska zmienia widok pracy. Uprawnienia do wspólnej bazy wynikają z konta i członkostwa w Supabase, a nie z wybranego kafelka stanowiska.

## GitHub → Cloudflare Pages

Repozytorium powinno zawierać zawartość tego katalogu, z `index.html` bezpośrednio w katalogu głównym. Zalecane jest prywatne repozytorium GitHub. Nie dodawaj do niego eksportów bazy, produkcyjnych PDF, haseł ani tokenów.

1. Utwórz repozytorium w GitHub i prześlij pliki tego katalogu, w tym katalog `.github`.
2. W Cloudflare otwórz **Workers & Pages → Create application → Pages → Import an existing Git repository** i wybierz repozytorium.
3. Ustaw nazwę projektu `machines-pioro-mes`, gałąź produkcyjną `main`, brak frameworka, polecenie budowania **`node scripts/build.cjs`**, katalog wynikowy **`public`**. Katalog główny pozostaw pusty, jeśli pliki leżą w głównym katalogu repozytorium.
4. Uruchom wdrożenie. Cloudflare nada projektowi adres `*.pages.dev`. Kolejne zmiany gałęzi `main` będą wdrażane przez integrację Git.

Skrypt budowania jedynie kopiuje `index.html` i `_headers`; nie wymaga instalacji pakietów. Do hostingu trafiają wyłącznie pliki aplikacji, bez SQL, dokumentacji, testów i danych użytkownika.

Alternatywnie można użyć ręcznie uruchamianego workflow **„Publikuj MES w Cloudflare Pages”**. Jest przeznaczony do istniejącego projektu Pages `machines-pioro-mes`. W GitHub ustaw sekrety `CLOUDFLARE_API_TOKEN` (token ograniczony do edycji Pages na właściwym koncie) i `CLOUDFLARE_ACCOUNT_ID`. Workflow korzysta ze środowiska `production`, gdzie można ustawić zasady publikacji. Nie konfiguruj równocześnie automatycznej integracji Git i workflow dla tej samej gałęzi, jeżeli nie chcesz podwójnych wdrożeń. Przy innej nazwie projektu zmień ją w `wrangler.jsonc` i workflow.

Konfiguracja Cloudflare jest oparta na [dokumentacji statycznych stron Pages](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/) i [poleceniu `pages deploy`](https://developers.cloudflare.com/workers/wrangler/commands/pages/). Uprawnienia workflow ograniczono do odczytu repozytorium zgodnie z [modelem uprawnień GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).

## Supabase: wspólna baza zakładu

1. Utwórz projekt Supabase. W **SQL Editor** uruchom cały plik `supabase/schema.sql` jako właściciel projektu. Tworzy on tabele, RLS, funkcje odczytu/zapisu oraz audyt zatwierdzonych wersji.
2. W **Authentication → Users** utwórz użytkownika administratora z hasłem i potwierdzonym adresem e-mail. Aplikacja loguje istniejące konta; nie prowadzi publicznej rejestracji ani samodzielnego dołączania do zakładu. Reset hasła i zarządzanie kontami odbywają się w Supabase.
3. W pliku `supabase/create-workspace.sql` wpisz adres administratora w miejsce `ZMIEN_NA_EMAIL_ADMINISTRATORA`. Uruchom plik raz. Skopiuj `workspace_id` zwrócony w wyniku.
4. W projekcie Supabase skopiuj adres **`https://…supabase.co`** oraz publiczny **publishable key** (`sb_publishable_…`). Publiczny klucz identyfikuje aplikację; dostęp do danych chronią logowanie oraz RLS. Nie używaj klucza `secret` ani `service_role` w przeglądarce. [Rodzaje kluczy Supabase](https://supabase.com/docs/guides/getting-started/api-keys).
5. Otwórz w aplikacji ustawienia połączenia Supabase. Wpisz adres, publiczny klucz i identyfikator zakładu. Zaloguj się e-mailem i hasłem utworzonego użytkownika.
6. Pobierz bazę firmową. Dla nowego zakładu ma ona wersję `0` i jest pusta. Dopiero po sprawdzeniu danych lokalnych wyślij je jako pierwszą wersję. Dane demo nie powinny zostać pomylone z rzeczywistą produkcją.
7. Na kolejnych urządzeniach wpisz te same parametry zakładu, zaloguj osobne konto i pobierz aktualną bazę.

Jeśli ustawisz własną domenę API Supabase, trzeba dostosować walidację adresu w kliencie i `connect-src` w `_headers`. Dostarczona konfiguracja obsługuje standardowe adresy projektów `*.supabase.co`.

### Dodanie pracownika

Najpierw utwórz i potwierdź konto w Supabase Auth. Następnie jako administrator projektu wykonaj w SQL Editor poniższe polecenie, zastępując oba pola własnymi danymi:

```sql
insert into public.mes_memberships (workspace_id, user_id, role)
select 'UUID_ZAKLADU'::uuid, id, 'operator'
from auth.users
where lower(email) = lower('EMAIL_PRACOWNIKA')
on conflict (workspace_id, user_id) do update set role = excluded.role;
```

`admin` i `operator` mogą przesyłać bazę zakładu. `viewer` może ją pobierać. Zarządzanie członkostwami wykonuje administrator projektu w Supabase; role aplikacyjne nie dostają prawa do edycji członkostw przez klienta. Konto bez członkostwa nie odczyta bazy, nawet jeżeli zna identyfikator zakładu. Konto `viewer` może eksperymentować z kopią lokalną, ale serwer nie przyjmie jego zmian.

### Synchronizacja i praca na kilku stanowiskach

Chmura przechowuje **wersjonowaną migawkę całej bazy**. Przesyłanie i pobieranie jest jawne; nie ma automatycznego scalania ani kanału Realtime. Przed rozpoczęciem pracy pobierz bieżącą wersję, po zmianach prześlij ją. Każdy zapis sprawdza numer wersji pod blokadą bazy danych. Dwa urządzenia nie mogą niezauważenie nadpisać tej samej wersji, także przy pierwszym zapisie.

Gdy ktoś zapisze wcześniej, pojawia się konflikt. **Wyeksportuj swoje lokalne zmiany**, pobierz aktualną bazę, wprowadź brakujące operacje ponownie i dopiero wtedy wyślij. Nie ponawiaj starych operacji magazynowych bez sprawdzenia, czy inne stanowisko już ich nie wykonało. Wspólna baza w tej wersji sprawdza się przy uzgodnionych cyklach synchronizacji; do intensywnej jednoczesnej pracy wielu stanowisk należy rozbudować zapis o transakcje poszczególnych operacji i współdzielone kolejki.

Sesja logowania jest przechowywana w `sessionStorage` bieżącej karty, hasło nie jest zapisywane. Dane lokalne i ustawienia połączenia pozostają w profilu przeglądarki również po wylogowaniu. Na współdzielonym stanowisku używaj osobnego profilu systemowego/przeglądarki i wyloguj konto po zmianie. Zmiana domeny aplikacji oznacza osobną pamięć lokalną.

### Limity i kopie

- Lokalny plik bazy ma limit walidacji 12 MiB; rzeczywisty limit `localStorage` zależy od przeglądarki i bywa mniejszy. Nieudany zapis nie powinien zastępować poprawnej bazy.
- Supabase przyjmuje maksymalnie **2 MiB na pełną migawkę**, łącznie z PDF zakodowanymi jako base64. To zwykle oznacza mniej niż 1,5 MiB surowych plików PDF. Zbyt dużą bazę trzeba zmniejszyć przed synchronizacją. Limit obejmuje reprezentację JSON po stronie serwera, która może zajmować nieco więcej miejsca niż eksport.
- Wgrywanie pojedynczego PDF w aplikacji ma limit **1 MiB**. Limit 2 MiB w Supabase obejmuje całą bazę i wszystkie kopie PDF w zleceniach oraz szablonach, więc kilka plików po 1 MiB nie zmieści się w jednej synchronizacji.
- PDF jest przechowywany wewnątrz bazy, dzięki czemu eksport JSON zawiera rysunki. Duże archiwum dokumentacji wymaga rozszerzenia o Supabase Storage i przechowywanie odnośników do plików.
- Twórz regularny eksport JSON oraz kopie projektu Supabase zgodnie z wybraną ofertą. Historia `mes_audit` zapisuje autora i numer zatwierdzonej wersji; nie przechowuje starszych pełnych migawek i nie zastępuje kopii zapasowej.

Funkcje RPC sprawdzają członkostwo i rolę, a bezpośredni zapis do tabel jest odebrany klientom. Schemat korzysta z [zasad RLS Supabase](https://supabase.com/docs/guides/database/postgres/row-level-security) oraz ograniczonych [funkcji bazodanowych](https://supabase.com/docs/guides/database/functions).

## Sprawdzenie przed uruchomieniem produkcji

Lokalnie, przy dostępnym Node.js 22 lub nowszym:

```text
node scripts/check.cjs
node --test tests/*.test.cjs
node scripts/build.cjs
```

Testy sprawdzają operacje MES i klienta Supabase przy symulowanych odpowiedziach serwera. `supabase/tests/security.sql` zawiera 23 testy pgTAP do uruchomienia w testowym projekcie Supabase po instalacji schematu. Sprawdzają m.in. odmowę dostępu anonimowego, brak samodzielnego podnoszenia roli, odczyt widza, blokadę zapisu widza, konflikt wersji, walidację danych i audyt. Testy bazodanowe nie są uruchamiane przez standardowy workflow GitHub, bo wymagają własnego projektu Supabase.

Bez podłączenia rzeczywistych kont nie można potwierdzić wdrożenia Cloudflare ani działania polityk w Twoim Supabase. Przed użyciem na produkcji uruchom testy SQL i wykonaj próbę z dwoma kontami na dwóch urządzeniach: pobranie tej samej wersji, dwa zapisy, oczekiwany konflikt drugiego zapisu, ponowny odczyt i sprawdzenie stanów materiału.

PDF.js 3.11.174 jest używany zgodnie ze specyfikacją, z `isEvalSupported: false`; nagłówki CSP nie dopuszczają `unsafe-eval`. Serwis nie osadza obcych stron ani nie wykonuje treści wyciągniętych z PDF.
