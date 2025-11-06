kubectl get secret -n davtrowebdb db-secret -o jsonpath='{.data.postgres-password}' | base64 --decode

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- cat /var/lib/postgresql/data/pgdata/pg_hba.conf

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- cat /var/lib/postgresql/data/pgdata/postgresql.conf | grep listen_addresses

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- ss -tlnp

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- netstat -tlnp

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- find / -name psql 2>/dev/null

kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- sh -c 'echo "SHOW listen_addresses;" | psql -U appuser -d appdb'


kubectl exec -n davtrowebdb db-5776c5dc94-jqd4n -- psql -U appuser -d appdb -c "SHOW listen_addresses;"

Ponadto, sprawdźmy, czy baza danych ma utworzonego użytkownika appuser i hasło jest poprawne. Możemy to zrobić, łącząc się z bazą danych i sprawdzając:

kubectl logs -n davtrowebdb db-5776c5dc94-jqd4n

# Uruchom tymczasowy pod do testowania połączenia
kubectl run -n davtrowebdb test-connection --image=postgres:14 --rm -it --restart=Never -- \
  sh -c 'apt-get update && apt-get install -y telnet && telnet db 5432'



kubectl get pods -n davtrowebdb -l app=website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.initContainerStatuses[*].state}{"\n"}{end}'


Aplikacja (website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin) nie może połączyć się z bazą danych, mimo że baza jest uruchomiona.

W logach aplikacji widać błędy odmowy połączenia na porcie 5432.

W konfiguracji ConfigMap ustawione jest połączenie: dbname=appdb user=appuser password=apppass host=db, co wygląda poprawnie.

W opisie poda bazy danych (db-5776c5dc94-jqd4n) widać, że używa ona hasła z secret db-secret, a w ConfigMap hasło jest ustawione na apppass. Być może hasło w secret nie jest apppass?

Sprawdźmy secret bazy danych:

bash
kubectl get secret -n davtrowebdb db-secret -o yaml
Jeśli hasło w secret nie jest apppass, to aplikacja nie będzie mogła się połączyć, ponieważ baza danych używa hasła z secret, a aplikacja używa hasła z ConfigMap.

Inna możliwość: baza danych może nie być jeszcze gotowa, gdy aplikacja próbuje się połączyć. W logach aplikacji widać, że próbuje kilkukrotnie, ale ostatecznie się nie udaje.

Możemy również sprawdzić, czy baza danych faktycznie nasłuchuje na porcie 5432 i czy jest dostępna z wewnątrz klastra.

Sprawdźmy, czy serwis db istnieje i ma poprawny adres:

bash
kubectl get svc -n davtrowebdb db
Jeśli serwis nie istnieje, to trzeba go utworzyć.

Jeśli serwis istnieje, to sprawdźmy, czy z wewnątrz poda aplikacji można połączyć się z bazą danych. Możemy to zrobić, uruchamiając polecenie nslookup i telnet (lub nc) z wewnątrz poda aplikacji.

Ponieważ aplikacja jest w CrashLoopBackOff, możemy tymczasowo uruchomić inny pod, aby przetestować połączenie:

bash
kubectl run -n davtrowebdb test-pod --image=postgres:14 --restart=Never --rm -it -- bash
Następnie wewnątrz poda:

bash
apt-get update && apt-get install -y telnet
telnet db 5432
Albo używając psql:

bash
psql -h db -U appuser -d appdb
Jeśli połączenie się nie powiedzie, to problem jest z bazą danych lub siecią.

Jeśli połączenie się powiedzie, to problem może leżeć w aplikacji (np. zła konfiguracja połączenia).

W logach aplikacji widać, że używa ona zmiennej środowiskowej DATABASE_URL z ConfigMap. Sprawdźmy, czy w podzie aplikacji ta zmienna jest ustawiona poprawnie.

Możemy to sprawdzić, opisując poda aplikacji:

bash
kubectl describe pod -n davtrowebdb <nazwa_poda_aplikacji>
W sekcji Containers.app.Environment powinna być zmienna DATABASE_URL ustawiona z ConfigMap.

Jeśli wszystko wygląda poprawnie, to może problem leży w tym, że aplikacja próbuje połączyć się z bazą zbyt wcześnie, zanim baza będzie gotowa. W takim przypadku możemy zwiększyć liczbę prób lub dodać opóźnienie w aplikacji.

W logach bazy danych nie widać błędów, więc prawdopodobnie baza działa poprawnie.

Sprawdźmy jeszcze, czy użytkownik appuser i baza appdb istnieją w bazie danych.

Możemy to zrobić, łącząc się z bazą danych z poda bazy:

bash
kubectl exec -n davtrowebdb -it db-5776c5dc94-jqd4n -- psql -U appuser -d appdb -c "SELECT usename FROM pg_user WHERE usename = 'appuser';"
Ale wcześniej musimy się upewnić, że w podzie bazy danych jest narzędzie psql. W opisie poda bazy danych widać, że używa obrazu postgres:14, który zawiera psql. Jednak wcześniejsze próby wykonania psql z poda bazy kończyły się błędem, że nie znaleziono pliku wykonywalnego. Być może dlatego, że używaliśmy kubectl exec z deploymentem db, a nie z podem. Spróbujmy z podem:

bash
kubectl exec -n davtrowebdb -it db-5776c5dc94-jqd4n -- psql -U appuser -d appdb -c "SELECT usename FROM pg_user WHERE usename = 'appuser';"
Jeśli to nie zadziała, to możemy wejść do poda i sprawdzić:

bash
kubectl exec -n davtrowebdb -it db-5776c5dc94-jqd4n -- bash
A następnie wewnątrz:

bash
psql -U appuser -d appdb -c "SELECT usename FROM pg_user WHERE usename = 'appuser';"




bash
# Tymczasowo uruchom pod z klientem PostgreSQL
kubectl run -n davtrowebdb postgres-client --rm --tty -i --restart='Never' --image postgres:14 --env="PGPASSWORD=apppass" --command -- psql -h db -U appuser -d appdb -c "SELECT usename FROM pg_user WHERE usename = 'appuser';"

5. Tymczasowe rozwiązanie - sprawdź connection string
Możesz też tymczasowo zmienić connection string w aplikacji:

bash
# Tymczasowo zmień connection string w aplikacji
kubectl patch deployment website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -n davtrowebdb -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "app",
            "env": [
              {
                "name": "DATABASE_URL",
                "value": "postgresql://appuser:apppass@db:5432/appdb"
              }
            ]
          }
        ]
      }
    }
  }
}'
1. Sprawdź czy aplikacja używa poprawnego connection string
bash
# Sprawdź ConfigMap z connection string
kubectl get configmap -n davtrowebdb website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin-config -o yaml

# Sprawdź czy aplikacja ma poprawną zmienną środowiskową
kubectl exec -n davtrowebdb -it deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -- env | grep DATABASE_URL
2. Przetestuj połączenie z bazy z wewnątrz Pod aplikacji
bash
# Sprawdź czy aplikacja może połączyć się z bazą
kubectl exec -n davtrowebdb -it deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -- \
  pg_isready -h db -U appuser -d appdb

# Jeśli powyższe nie działa, spróbuj z hasłem:
kubectl exec -n davtrowebdb -it deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -- \
  sh -c 'PGPASSWORD=apppass pg_isready -h db -U appuser -d appdb'
3. Sprawdź czy baza akceptuje połączenia
bash
# Sprawdź logi PostgreSQL - czy są błędy uwierzytelniania?
kubectl logs -n davtrowebdb -l app=db

# Sprawdź czy użytkownik appuser istnieje w bazie
kubectl exec -n davtrowebdb -it deployment/db -- \
  psql -U appuser -d appdb -c "SELECT usename FROM pg_user WHERE usename = 'appuser';"


kubectl rollout restart deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -n davtrowebdb

6. Sprawdź czy aplikacja może rozwiązać nazwę 'db'
bash
# Sprawdź DNS wewnątrz Pod aplikacji
kubectl exec -n davtrowebdb -it deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -- nslookup db

# Sprawdź połączenie sieciowe
kubectl exec -n davtrowebdb -it deployment/website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin -- nc -zv db 5432



Z powyższych informacji wynika, że serwis db istnieje i ma ClusterIP 10.152.183.183, który jest tym samym adresem, do którego aplikacja próbuje się połączyć (jak widać w logach aplikacji: connection to server at "db" (10.152.183.183), port 5432 failed: Connection refused).

Problem nie leży w samym serwisie, ale w tym, że serwis nie ma endpointów. Sprawdźmy endpointy dla serwisu db:

bash
kubectl get endpoints db -n davtrowebdb
Jeśli endpointy są puste, oznacza to, że serwis nie znalazł żadnych podów z etykietami pasującymi do selektora serwisu. Selektor serwisu db to app: db, a z opisu poda PostgreSQL widać, że ma on etykietę app: website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin. Dlatego serwis nie może znaleźć poda PostgreSQL.

Rozwiązaniem jest zmiana etykiet na podach PostgreSQL na app: db albo zmianę selektora serwisu na app: website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin. Jednak lepiej jest dostosować deployment PostgreSQL do używania etykiety app: db, ponieważ tak jest skonfigurowany serwis.

W poprzednim kroku już zaproponowałem poprawiony plik postgres.yaml, który ustawia etykietę app: db na podach PostgreSQL. Należy go zastosować.

Jeśli jednak nie chcesz usuwać i ponownie tworzyć deploymentu PostgreSQL, możesz zmodyfikować etykiety na istniejących podach:

bash
kubectl label pods -n davtrowebdb -l app=website-db-argocd-kustomize-kyverno-grafana-loki-tempo-pgadmin app=db --overwrite
Ale uwaga: deployment PostgreSQL nadal będzie tworzył pody z starą etykietą, więc lepiej jest zaktualizować deployment.

Możesz również tymczasowo zmienić selektor serwisu, ale to nie jest zalecane, ponieważ serwis jest zarządzany przez ArgoCD i może zostać nadpisany.

Dlatego najlepszym rozwiązaniem jest zaktualizowanie deploymentu PostgreSQL w pliku k8s/base/postgres.yaml i ponowne zastosowanie go.

Jeśli już zastosowałeś poprawiony plik postgres.yaml i nadal masz problem, to być może stary pod PostgreSQL nadal działa z starą etykietą. Usuń stary deployment i pod, a następnie utwórz je ponownie.

Sprawdź, czy po zastosowaniu poprawionego postgres.yaml nowy pod PostgreSQL ma etykietę app: db:

bash
kubectl get pods -n davtrowebdb --show-labels | grep db
Powinieneś zobaczyć coś takiego:

text
db-5776c5dc94-jqd4n   1/1     Running   0          5m   app=db,environment=development,pod-template-hash=5776c5dc94
Następnie sprawdź endpointy serwisu db:

bash
kubectl get endpoints db -n davtrowebdb