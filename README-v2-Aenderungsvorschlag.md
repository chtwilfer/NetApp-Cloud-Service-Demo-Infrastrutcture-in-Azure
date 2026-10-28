# Änderungsvorschlag für NCSDemoInfra-v2.ps1

Dieses Dokument beschreibt die geplanten Änderungen für die nächsten beiden Schritte. **Das PowerShell-Skript und die Terraform-Dateien werden in diesem Schritt nicht geändert.** Bitte den Vorschlag prüfen und freigeben oder die offenen Entscheidungen anpassen. Erst danach würde Schritt 1 und 2 in `NCSDemoInfra-v2.ps1` umgesetzt. Die Übernahme nach Terraform ist ausdrücklich Schritt 3.

## Zielbild

1. Eine Ubuntu-Linux-VM im North-Europe-Spoke erstellen, eine grafische Oberfläche bereitstellen und sie für den späteren Mount des dortigen Azure NetApp Files NFSv3-Volumes vorbereiten.
2. Für neue Demo-Bereitstellungen Windows Server 2019 durch Windows Server 2025 als Betriebssystem des Domain Controllers ersetzen.
3. Nach deiner Freigabe die PowerShell-Version ändern und separat validieren.
4. Erst danach dieselben Änderungen in den `infra`-Terraform-Ordner übertragen.

## Schritt 1: Ubuntu-VM mit grafischer Oberfläche und ANF-NFS

### Vorgeschlagene Platzierung

Die VM sollte in der vorhandenen North-Europe-Spoke-Resource-Group und im `Spoke-VNet` erstellt werden. Das aktuelle Spoke-VNet enthält nur das für Azure NetApp Files delegierte Subnetz. Darin darf die Linux-VM nicht platziert werden.

Daher würde ich ergänzen:

- Ein separates Client-Subnetz im Spoke-VNet, vorgeschlagener Name `LinuxClientSubnet`.
- Als erster Vorschlag das freie Prefix `10.3.1.0/24` innerhalb von `10.3.0.0/16`.
- Die Ubuntu-VM erhält eine NIC in diesem Client-Subnetz und eine private IP. Es wird keine öffentliche IP für die VM angelegt.
- Der Zugriff erfolgt über den vorhandenen Azure Bastion Host im Hub und das bestehende Hub-Spoke-Peering.

Das Prefix ist ein Vorschlag und muss mit der bestehenden Netzplanung abgeglichen werden. Für eine restriktive NSG würde ich Verbindungen zur VM nur aus dem Bastion-Subnetz `10.2.2.0/26` zulassen. Die erforderlichen Bastion-Regeln und die für NFSv3 nötigen Netzwerkports müssen vor der Umsetzung gegen die aktuelle Azure-Dokumentation geprüft werden.

### Ubuntu-Image und Desktop

Vorgeschlagene Basis ist ein aktuelles Ubuntu Server LTS Marketplace-Image. Darauf würde das Skript beim ersten Start installieren:

- Eine leichte Desktop-Umgebung, vorzugsweise XFCE, um den Ressourcenbedarf gegenüber einem vollständigen GNOME-Desktop zu begrenzen.
- `xrdp` für die grafische Sitzung über RDP durch Bastion.
- `nfs-common` für den NFS-Client.

Für die Linux-VM sollte eine eigene, konfigurierbare VM-Größe verwendet werden. Als Startwert würde ich eine Größe mit mindestens 2 vCPU und 8 GiB RAM einplanen; die konkrete SKU ist vor Umsetzung für North Europe auf Verfügbarkeit, Quota und Kosten zu prüfen. Das ist eine Planungsannahme, keine bereits bestätigte regionale Verfügbarkeit.

Die Anmeldung sollte nicht über eine öffentliche SSH- oder RDP-Freigabe erfolgen. Für SSH ist ein eigener öffentlicher SSH-Schlüssel als Eingabe vorzusehen. Für eine grafische RDP-Sitzung wird zusätzlich ein separates Linux-Anmeldekennwort benötigt. Dieses Kennwort sollte interaktiv und geschützt abgefragt oder aus einer freigegebenen Secret-Quelle bezogen werden, nicht fest im Skript stehen.

### NFS-Mount vorbereiten

Das ANF-Volume in North Europe wird bereits im v2-Skript erstellt. Ergänzt werden müsste danach:

1. Den Mount-Target des erstellten Volumes aus dem Azure-Ergebnis ermitteln, statt eine IP-Adresse fest zu codieren.
2. Das Volume mit seinem Volume-Pfad, dem gefundenen Mount-Target und NFSv3 auf der Linux-VM mounten.
3. Einen Mountpunkt wie `/mnt/anf-demo` anlegen.
4. Den Eintrag idempotent in `/etc/fstab` schreiben, mit Optionen wie `_netdev` und `nofail`, sodass ein temporär nicht erreichbares ANF den VM-Start nicht blockiert.
5. Den Mount mit `mount -a` prüfen und einen verständlichen Fehler ausgeben, falls der Share nicht erreichbar ist.

Der aktuelle Volume-Pfad in North Europe ist `myfilepath2`. Im Skript würde ich ihn aus der zentralen ANF-Konfiguration lesen, damit Volume-Erstellung und Mount nicht auseinanderlaufen. Für produktionsnahe Verwendung sollte die ANF-Export-Policy auf das Client-Subnetz begrenzt werden. Derzeit enthält die v2-Konfiguration noch keine explizite Export-Policy; ich würde vor der Umsetzung festlegen, ob Schreibzugriff erlaubt sein soll und ob Root-Zugriff benötigt wird. Mein sicherer Standardvorschlag wäre Schreibzugriff nur aus dem Linux-Client-Subnetz und kein Root-Zugriff.

### Betroffene Abschnitte in v2

- Parameter: Linux-VM-Schalter bzw. Konfiguration, Ubuntu-Image, VM-Größe, SSH Public Key, Login-Name, Mountpunkt und gegebenenfalls separate RDP-Anmeldung.
- Regions-/Netzwerkkonfiguration: Client-Subnetz für North Europe ergänzen und in die CIDR-Überlappungsprüfung aufnehmen.
- Vorabprüfung: Ubuntu-Image und VM-SKU in North Europe, Public-Key-Datei, Subnetz- und Mount-Parameter prüfen.
- Deployment-Plan: zusätzliche NIC und Ubuntu-VM aufführen.
- Spoke-Netzwerk: Client-Subnetz zusätzlich zum delegierten ANF-Subnetz anlegen.
- Bereitstellungsabschnitt: Ubuntu-VM erstellen und die Cloud-Init- oder Custom-Script-Konfiguration für Desktop, `xrdp`, NFS-Client und Mount ausführen.
- ANF-Konfiguration: Mount-Target nach der Volume-Erstellung ermitteln und die erlaubten Clients gegebenenfalls auf das Linux-Subnetz begrenzen.
- Abschlussmeldungen und Dokumentation: private Erreichbarkeit über Bastion und NFS-Mount-Pfad ausgeben.

## Schritt 2: Domain Controller auf Windows Server 2025 umstellen

### Vorgeschlagene Änderung für neue Bereitstellungen

Für neu erstellte Demo-Umgebungen würde ich die Windows-Image-Auswahl zentral konfigurierbar machen und den Standard von `2019-Datacenter` auf die passende Windows-Server-2025-Datacenter-SKU ändern. Der endgültige Marketplace-SKU-Name und die Verfügbarkeit von Image und `Standard_D2_v3` müssen vor Umsetzung in West Europe geprüft werden.

Der VM-Name `WinDC01`, die Domain `anfdemo.intra`, das separate DSRM-Kennwort und die AD-DS-Custom-Script-Extension können grundsätzlich erhalten bleiben. Das Bootstrap-Template muss aber gegen Windows Server 2025 geprüft werden. Dabei würde ich insbesondere die Installation des AD-DS-Features, Forest-Erstellung, Neustart und Extension-Ergebnis testen. Vor der Umsetzung ist außerdem zu entscheiden, ob ein bestimmter Domain-/Forest-Funktionsebene-Wert gesetzt werden soll oder ob das bisherige Verhalten ohne explizite Einstellung erhalten bleibt.

### Wichtig: neues Image ist keine Migration einer bestehenden VM

Die v2-Datei erstellt nur neue Demo-Resource-Groups und bricht ab, wenn die Zielgruppen bereits existieren. Ein Wechsel des Marketplace-Images ändert deshalb ausschließlich neu erstellte Umgebungen; er aktualisiert keinen bestehenden Windows-Server-2019-Domain-Controller.

Falls bereits ein laufender 2019-Domain-Controller beziehungsweise eine bestehende AD-Forest migriert werden soll, ist das ein separates Migrationsvorhaben. Dann darf die bestehende VM nicht einfach durch eine neue VM mit demselben Namen ersetzt werden. Üblicherweise wären ein zusätzlicher Windows-Server-2025-Domain-Controller, Replikationsprüfung, kontrollierte Übertragung der Rollen und anschließende Demotion des alten Domain Controllers zu planen. Das ist nicht Teil des hier vorgeschlagenen Skriptwechsels.

### Betroffene Abschnitte in v2

- Parameter/Konfiguration: Windows-Server-Image-SKU zentral definieren, mit 2025 als Standard für neue Deployments.
- Vorabprüfung: das konkrete 2025-Image und die VM-SKU in West Europe prüfen.
- Deployment-Plan und Statusausgaben: Windows Server 2025 statt 2019 nennen.
- VM-Erstellung: ausschließlich die Source-Image-SKU für neue VMs aktualisieren.
- AD-DS-Bootstrap: Kompatibilität der Feature-Installation und Forest-Erstellung mit Server 2025 prüfen, Fehler sauber melden und Neustart kontrolliert behandeln.
- Dokumentation: klar sagen, dass die Änderung neue Deployments betrifft und keine bestehende 2019-Installation migriert.

## Vorgeschlagene Reihenfolge und Tests

1. Diesen Vorschlag abstimmen; besonders GUI-Variante, Zugriffspfad und NFS-Schreibrechte festlegen.
2. Ubuntu-Image/SKU und Server-2025-Image/SKU in den Zielregionen verifizieren.
3. Schritt 1 und 2 in `NCSDemoInfra-v2.ps1` umsetzen, ohne die bestehende Terraform-Konfiguration anzufassen.
4. PowerShell-Parser und `-WhatIf`-Plan prüfen; sicherstellen, dass Linux-Subnetz und beide VMs im Plan erscheinen.
5. In einer neuen, nicht produktiven Subscription deployen und Ubuntu-GUI, Bastion-Zugriff, NFS-Mount nach Neustart sowie AD-DS-Installation prüfen.
6. Nach erfolgreicher Abnahme Schritt 3 durchführen und die Änderungen in Terraform übertragen.

## Entscheidungen vor der Umsetzung

- Ist XFCE mit `xrdp` über Bastion als grafische Oberfläche in Ordnung, oder soll eine andere Desktop-Umgebung verwendet werden?
- Soll die Ubuntu-VM im North-Europe-Spoke in `10.3.1.0/24` liegen? Das Prefix ist noch zu bestätigen.
- Soll der NFSv3-Share nur vorbereitet oder direkt automatisch gemountet werden? Der Vorschlag oben sieht automatischen, persistenten Mount vor.
- Soll die ANF-Export-Policy Schreibzugriff aus dem gesamten Client-Subnetz erlauben? Root-Zugriff würde ich standardmäßig deaktiviert lassen.
- Geht es bei Windows Server 2025 nur um neue Demo-Deployments, oder soll später auch eine bestehende 2019-AD-Umgebung migriert werden? Diese beiden Fälle benötigen unterschiedliche Vorgehensweisen.

## Änderungsgrenze dieses Schritts

Es wurde ausschließlich dieser Vorschlag erstellt. `NCSDemoInfra-v2.ps1`, die vorhandene `infra`-Terraform-Konfiguration und andere Dateien wurden in diesem Schritt nicht geändert. Es wurde kein Azure-Image- oder Quota-Livecheck und kein Deployment ausgeführt.
