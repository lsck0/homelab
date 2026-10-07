# ntfy on vm-203 (instances/203-external-ntfy/main.nix): its topics, one place for the server's grants and the publishers
# (grafana on vm-105, hermes' lab-notify on vm-114)
{
  topics = {
    # grafana's alerts, the owner's alert channel; nobody else publishes there
    alerts = "homelab-alerts";
    # grafana's always-firing watchdog, every heartbeatIntervalMin; vm-203 alerts on `alerts` when it falls silent
    heartbeat = "homelab-heartbeat";
    # hermes reports to the owner here
    hermes = "homelab-hermes";
  };
  # grafana repeats the watchdog this often; vm-203's check runs at the same period
  heartbeatIntervalMin = 5;
}
