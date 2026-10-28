# Review: NCSDemoInfra.ps1

## Kurzfazit

Das Skript bildet den Demo-Aufbau nachvollziehbar ab, ist aber ein interaktives Einmal-Skript und noch kein sicher wiederholbares Deployment. Die groessten Verbesserungen mit wenig Umbau sind:

1. Den fehlerhaften Aufruf der VM-Extension korrigieren.
2. Keine globale Execution-Policy setzen und Module nicht bei jedem Lauf erzwingen/installieren.
3. Fehler sofort abbrechen lassen und die Azure-Subscription explizit auswaehlen.
4. Subnetze ueber Namen/Objekte statt ueber Array-Indizes adressieren.
5. Die wiederholten ANF- und Peering-Bloecke in wenige Funktionen mit Regionskonfiguration ueberfuehren.
6. Den Einsatz von ONTAP/GFC klar als Vorbereitung fuer NetApp Cloud Manager beschreiben, nicht als Deployment durch dieses Skript.

Das Original wurde nicht veraendert. Dieser Bericht bewertet den vorhandenen Code und schlaegt eine schrittweise Vereinfachung vor. Es wurde kein Azure-Deployment ausgefuehrt.

Die Empfehlungen sind in [NCSDemoInfra-v2.ps1](NCSDemoInfra-v2.ps1) umgesetzt. Die neue Datei behaelt den Hub-/Spoke-Ablauf und die optionalen ONTAP-/GFC-Netzwerkvorbereitungen bei; das Original bleibt als Vergleich unveraendert. Die README beschreibt jetzt die neue Version und vermeidet den frueheren Wildcard-Cleanup-Befehl.

## Befunde nach Prioritaet

### Hoch: VM-Extension bekommt einen falschen VM-Namen

Im Domain-Controller-Block steht:

```powershell
Set-AzVMExtension ... -VMName = "WinDC01" ...
```

PowerShell akzeptiert diese Zeile syntaktisch. Die AST-Pruefung zeigt aber, dass `-VMName` den Wert `=` erhaelt und `"WinDC01"` als separates Argument folgt. Dadurch kann die Extension nicht korrekt an `WinDC01` gebunden werden. Korrekt ist:

```powershell
Set-AzVMExtension ... -VMName "WinDC01" ...
```

Die restlichen Parameter sollten ebenfalls ohne unnötige Positionsargumente gesetzt und mit `-ErrorAction Stop` ausgefuehrt werden.

### Hoch: Globale Aenderung der Execution Policy

`Set-ExecutionPolicy unrestricted -force` aendert eine PowerShell-Sicherheitseinstellung ausserhalb des Skripts; ohne `-Scope` gilt typischerweise `LocalMachine`. Das ist fuer die Azure-Bereitstellung nicht erforderlich und kann eine administrative Konfiguration dauerhaft abschwaechen. Die Zeile sollte entfallen. Falls eine lokale Richtlinie die Ausfuehrung verhindert, sollte die Richtlinie gezielt und bewusst durch den Betreiber geregelt werden, nicht automatisiert durch das Deployment.

### Hoch: Domain-Admin-Kennwort wird wiederverwendet und in ein Skript eingesetzt

Das mit `Get-Credential` abgefragte Kennwort wird zugleich als lokales VM-Administrator- und DSRM-Kennwort verwendet. Anschliessend wird es als Klartext in `$DCInstallScript` eingesetzt und die gesamte Befehlszeile lediglich Base64-kodiert. Base64 ist keine Verschluesselung. Die Azure Custom Script Extension verwendet zwar geschuetzte Einstellungen, aber der Klartext existiert zuvor im PowerShell-Prozess und in der daraus erzeugten Zeichenfolge.

Empfehlung:

- Separates DSRM-Kennwort verwenden und nicht das VM-Admin-Kennwort wiederverwenden.
- Geheimnisse nicht in Transcript-, Verbose- oder Fehlerausgaben schreiben.
- Fuer automatisierte Laeufe einen kontrollierten Secret-Bezug verwenden (zum Beispiel Key Vault mit geeignetem Identitaets-/Berechtigungsmodell). Fuer interaktive Demos zumindest die Eingabe getrennt halten und die Secret-Uebergabe bewusst absichern.
- Die Custom Script Extension nicht als allgemeines Geheimnis-Transportmittel behandeln.

### Hoch: Fehler koennen unbemerkt Folgeaktionen ausloesen

Es gibt kein einheitliches `-ErrorAction Stop`, kein `try/catch` und keine abschliessende Fehlerbehandlung. Bei einem fehlgeschlagenen Resource-Group-, Netzwerk-, VM- oder ANF-Schritt laeuft das Skript moeglicherweise weiter und meldet spaeter Erfolg oder oeffnet Portale, obwohl die Infrastruktur nur teilweise existiert.

Am Skriptanfang sollte mindestens gelten:

```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param(...)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Die Deployment-Abschnitte sollten in `try/catch/finally` liegen. In `finally` kann ein Transcript geschlossen werden; Geheimnisse und geschuetzte Extension-Einstellungen duerfen dabei nicht protokolliert werden. Fuer produktionsnahe Nutzung sollte ausserdem ein `-WhatIf`-Lauf vorgesehen sein.

### Mittel: Subscription-Auswahl ist interaktiv und nicht reproduzierbar

`Out-GridView -PassThru` setzt eine Desktop-Sitzung voraus und macht das Skript fuer CI, Remote-Shells und reproduzierbare Laeufe unbrauchbar. Eine versehentlich ausgewaehlte Subscription kann zudem die falschen Ressourcen erhalten.

Eine explizite `-SubscriptionId` als Parameter ist robuster. Nach `Connect-AzAccount` sollte das Skript den Kontext setzen und vor dem ersten Schreibzugriff Subscription-ID und Tenant anzeigen oder validieren. Die benoetigten Azure-Rollen sollten als Voraussetzung dokumentiert werden; lokale Administratorrechte sind nicht automatisch gleichbedeutend mit Azure-Berechtigungen.

### Mittel: Module werden bei jedem Lauf installiert/aktualisiert

Der `else`-Zweig fuehrt jedes Mal `Install-Module -Name Az -AllowClobber -Force` aus. Das ist langsam, setzt PSGallery-Zugriff voraus und kann bei unveraenderten Skripten das Laufzeitverhalten durch eine neue Modulversion aendern. Das Skript prueft auch nicht gezielt, ob die benoetigten Az-Teilmodule vorhanden sind.

Einfacher und sicherer ist eine reine Vorbedingungspruefung: erforderliche Module und Mindestversionen benennen, bei Fehlen mit einer klaren Installationsanweisung abbrechen und anschliessend importieren. Installation/Update gehoert in einen separaten Setup-Schritt. Den AzureRM-Konflikt nur als Diagnose auszugeben reicht nicht, wenn der Lauf danach trotzdem fortgesetzt wird.

### Mittel: Subnetz-IDs haengen von der Reihenfolge im Array ab

Die Zuweisungen `$vnetDC.Subnets[1].Id`, `$vnetANF.Subnets[2].Id` und `$secondvnetanf.Subnets[0].Id` setzen voraus, dass Azure die Subnetze in genau dieser Reihenfolge liefert. Die Absicht ist aber die Auswahl nach Namen (`DomainServicesSubnet` bzw. dem konfigurierten ANF-Subnetznamen).

Besser ist, alle Subnetze vor dem VNet-Aufruf anzulegen und die passende Konfiguration direkt zu referenzieren. Wenn ein erneutes `Get-AzVirtualNetwork` erforderlich ist, danach explizit nach `Name` suchen und bei fehlendem Treffer abbrechen:

```powershell
$anfSubnet = $vnet.Subnets | Where-Object Name -eq $VirtualANFSubnetName
if (-not $anfSubnet) {
    throw "ANF subnet '$VirtualANFSubnetName' not found in VNet '$VirtualNetworkName'."
}
$subnetId = $anfSubnet.Id
```

### Mittel: Wiederholte Ausfuehrungen haben keinen definierten Zustand

Resource Groups, VNets, Peering, Extensions und ANF-Ressourcen werden ohne einheitliche Existenz- oder Zustandspruefung angelegt. Ein zweiter Lauf kann je nach Cmdlet scheitern, Einstellungen ueberschreiben oder inkonsistente Teilzustaende hinterlassen. Das ist besonders kritisch, weil ein Fehler in der Mitte keinen kontrollierten Rollback ausloest.

Vor einer Vereinfachung sollte entschieden werden, ob das Skript bewusst nur einmal laeuft oder einen vorhandenen Zielzustand herstellen soll. Fuer die zweite Variante sind pro Ressource `Get-*`/Create-or-Update-Logik, Namens-/Konfigurationsvalidierung und ein getesteter Wiederholungslauf noetig. Ein `-WhatIf`-Parameter allein macht Azure-Aufrufe nicht automatisch sicher; die Schreiboperationen muessen `ShouldProcess` tatsaechlich beachten.

### Mittel: ONTAP- und GFC-Schalter deployen diese Produkte nicht

`-deployONTAP` und `-deployGFC` erstellen jeweils eine Resource Group, ein VNet und Peering und oeffnen anschliessend Cloud-Manager-/Dokumentationsseiten. CVO bzw. Global File Cache werden nicht durch dieses Skript bereitgestellt. Kommentar, README und Ausgaben sollten das als "Netzwerk vorbereiten" bezeichnen. Die Kommentarzeile zu ONTAP spricht von einer anderen Region, waehrend `$thirdlocation` tatsaechlich `westeurope` ist.

### Mittel: Bastion- und ANF-Voraussetzungen sind nicht vorab geprueft

Das Bastion-Subnetz ist mit `/27` festgelegt. Vor dem Deployment muss geprueft werden, ob Prefix und SKU den aktuell geltenden Bastion-Anforderungen entsprechen; die bestehende Groesse ist eine moegliche Bereitstellungsblockade. Entsprechend fehlen Vorabpruefungen fuer Provider-Registrierung, regionale ANF-Verfuegbarkeit, Quotas, erlaubte VM-SKUs und gueltige Customer-/Ressourcennamen.

Die Feature-Registrierung ist auskommentiert. Wenn sie Voraussetzung ist, muss der Betreiber sie vorab erledigen oder das Skript muss den Status pruefen, Registrierung bei Bedarf starten und mit Timeout auf den Abschluss warten. Ein unbegrenzter `while`-Loop ohne Timeout waere dabei ebenfalls zu vermeiden.

### Niedrig: Unnoetige VNet-Schreibaufrufe und unklare Meldungen

Im Peering-Abschnitt werden VNets abgerufen und direkt ohne Aenderung wieder mit `Set-AzVirtualNetwork` gespeichert. Diese Schreibaufrufe sind nicht erforderlich, um ein Peering anzulegen, und erschweren das Verstaendnis. Die Resource Groups fuer die optionalen Netze werden als "ONTAP" bzw. "GFC" bezeichnet, obwohl dort nur Netzwerkressourcen vorbereitet werden.

Ausserdem werden Portal-Seiten und ein `Read-Host`-Prompt immer am Ende geoeffnet. Das verhindert unbeaufsichtigte Ausfuehrung. Interaktive Hinweise sollten optional sein, etwa ueber einen Schalter, oder in eine Abschlussmeldung mit URLs umgewandelt werden.

## Vereinfachungsvorschlag

Die groesste sichere Vereinfachung ist keine komplette Neuentwicklung, sondern das Zusammenfassen der strukturell gleichen West-/North-Europe-Bloecke. Netzwerkkonfigurationen gehoeren in Daten, die wiederholte Arbeit in wenige Funktionen; der Domain Controller bleibt ein eigener, klar abgegrenzter Schritt.

Eine moegliche Regionskonfiguration:

```powershell
$anfRegions = @(
    @{
        Location = 'westeurope'
        ResourceGroup = "$CustomerName-Demo-ANF-Hub"
        Account = "$CustomerName-ANF-Account-WE"
        Pool = "$CustomerName-ANF-Account-WE-pool-WE"
        VNet = 'Hub-VNet'
        VNetPrefix = '10.2.0.0/16'
        AnfSubnet = "$CustomerName-ANF-Account-WE-ANF-subnet-WE"
        AnfSubnetPrefix = '10.2.5.0/24'
        Volume = "$CustomerName-ANF-Account-WE-NFS-volume-WE"
        CreationToken = 'myfilepath1'
        CreateSnapshot = $true
    },
    @{
        Location = 'northeurope'
        ResourceGroup = "$CustomerName-Demo-ANF-Spoke"
        Account = "$CustomerName-ANF-Account-NE"
        Pool = "$CustomerName-ANF-Account-NE-pool-NE"
        VNet = 'Spoke-VNet'
        VNetPrefix = '10.3.0.0/16'
        AnfSubnet = "$CustomerName-ANF-Account-NE-ANF-subnet-NE"
        AnfSubnetPrefix = '10.3.5.0/24'
        Volume = "$CustomerName-ANF-Account-NE-NFS-volume-NE"
        CreationToken = 'myfilepath2'
        CreateSnapshot = $false
    }
)
```

Darauf kann eine Funktion `New-AnfRegion` die Resource Group, das VNet/Subnetz, Account, Pool, Volume und optional den Snapshot erstellen. Die Funktion sollte die Subnet-ID anhand des Namens ermitteln und jeden Azure-Aufruf fehlerbehandelt ausfuehren. Ein zweiter kleiner Helfer kann bidirektionales VNet-Peering anlegen. So verschwinden die duplizierten Bloecke, ohne jede Ressource in eine eigene Funktion zu zerlegen.

Die Werte fuer Pool- und Volume-Groesse, Service Level, Protokoll und Prefixes sollten zentral konfiguriert oder als Parameter angeboten werden. Die aktuellen 4-TiB-Pools und 100-GiB-Volumes sind fixe Demo-Entscheidungen und sollten als solche dokumentiert werden.

## Empfohlene Reihenfolge

1. Den `-VMName =`-Aufruf korrigieren; Syntaxpruefung allein reicht nicht, daher Command-Argumente bzw. einen Pester-Test pruefen.
2. `Set-ExecutionPolicy` und die automatische Modulinstallation entfernen; Voraussetzungen klar melden.
3. Fehlerabbruch, explizite Subscription und sichere Secret-Behandlung einziehen.
4. Subnetze nach Namen referenzieren und Bastion-/ANF-Voraussetzungen vorab validieren.
5. Doppelte ANF- und Peering-Logik in kleine Funktionen und Konfigurationsdaten ueberfuehren.
6. Wiederholbarkeit und `-WhatIf` gezielt implementieren und mit einem Test-/Demo-Abonnement pruefen.
7. README und Kommentare an das tatsaechliche Verhalten anpassen; Cleanup nur mit exakten Resource-Group-Namen, deutlicher Bestaetigung und niemals per ungesichertem Wildcard-Delete anbieten.

## Pruefung

- PowerShell-Parser fuer `NCSDemoInfra-v2.ps1`: keine Syntaxfehler gefunden.
- `-WhatIf` fuer Basisdeployment und optionale ONTAP-/GFC-Netzwerkpfade ausgefuehrt; der Plan beendet sich vor Anmeldung und Azure-Schreibzugriffen.
- Die Editor-Diagnose meldete zwischenzeitlich eine nicht mehr vorhandene Variable. Direkte Suche und Parserpruefung bestaetigten, dass sie nicht im aktuellen Skript steht.
- Kein Azure-Deployment und keine Azure-Cmdlet-Laufzeitpruefung ausgefuehrt; dafuer waeren Az-Module, Subscription-Kontext und Azure-Berechtigungen erforderlich.

## Umsetzungsstand und Grenzen

- Sicherheits- und Ablaufempfehlungen: keine globale Execution-Policy-Aenderung, keine automatische Modulinstallation, explizite Subscription-ID, Fehlerabbruch, separate VM-/DSRM-Kennworteingabe und keine Geheimnisse in der eigenen Logdatei.
- Vereinfachung: regionale ANF-Ressourcen liegen in einer Konfiguration und werden ueber dieselbe Funktion erstellt; Peering ist in einer Funktion gebuendelt. Subnetze werden nach Namen ermittelt. Bastion verwendet ein `/26`-Subnetz.
- Schutz vor unbeabsichtigter Wiederholung: Die neue Version ist bewusst kein Update-/Reconcile-Skript. Sie bricht ab, sobald eine der exakt geplanten Resource Groups bereits existiert. Ein Fehler nach Beginn des Deployments kann trotzdem bereits erstellte Ressourcen hinterlassen; diese muessen gezielt geprueft werden.
- Vor dem echten Lauf muessen ANF-Region, Quota/Kapazitaet und eventuell erforderliche Provider-Features fuer die konkrete Subscription geprueft werden. Die VM-SKU und die statischen IPv4-Adressbereiche werden vorab geprueft.
- Das DSRM-Kennwort wird separat abgefragt und ausschliesslich als geschuetzte VM-Extension-Einstellung uebergeben. Es liegt dafuer temporaer im PowerShell-Prozess und in einer Base64-kodierten Befehlszeichenfolge vor; Base64 ist keine Verschluesselung. Fuer unbeaufsichtigte oder produktionsnahe Nutzung sollte die Secret-Uebergabe auf Key Vault/Managed Identity umgestellt werden.
- Es gibt keinen Cleanup-Modus. Die README empfiehlt nur noch die Pruefung und den `-WhatIf`-Preview mit exakt angegebenen Resource-Group-Namen, keine Wildcard-Loeschung.
