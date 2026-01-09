kubectl -n davtrowebdbvault get pods -w
NAME                                 READY   STATUS             RESTARTS         AGE
fastapi-web-app-5bcf7cf645-t749v     1/1     Running            1                22h
fastapi-web-app-5bcf7cf645-xc2n9     1/1     Running            1                22h
grafana-85f4f845b-vk6sj              1/1     Running            1                22h
kafka-0                              1/1     Running            0                139m
kafka-exporter-8464d44cc7-8kfx4      1/1     Running            0                22h
kafka-ui-85b5756c69-h9jwz            0/1     CrashLoopBackOff   37 (3m32s ago)   22h
loki-0                               1/1     Running            1                22h
message-processor-856c58d56d-z2wzx   0/1     Running            25 (2m24s ago)   133m
node-exporter-jvpvc                  1/1     Running            1                22h
pgadmin-bc8568799-6h7wg              1/1     Running            1                22h
postgres-db-0                        1/1     Running            1                22h
postgres-exporter-7db8799c9c-sfnh8   1/1     Running            1                22h
prometheus-59f9845cdd-tmfmq          1/1     Running            1                22h
promtail-svz7d                       1/1     Running            1                22h
redis-6d448bdd7f-pv85c               1/1     Running            1                22h
tempo-0                              1/1     Running            1                22h
vault-0                              1/1     Running            1                22h
vault-init-86vfs                     0/1     Completed          0                22h
message-processor-856c58d56d-z2wzx   0/1     CrashLoopBackOff   25 (1s ago)      134m
kafka-ui-85b5756c69-h9jwz            0/1     Running            38 (5m6s ago)    22h