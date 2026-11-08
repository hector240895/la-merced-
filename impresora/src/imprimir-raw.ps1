# Envía bytes ESC/POS tal cual (RAW) a una impresora de Windows y espera a que
# Windows confirme que salieron. Si la impresora no responde (apagada, sin
# papel, desconectada), cancela el trabajo para que no salga después repetido.
#   0 = impreso   2 = la impresora no respondió   1 = otro error
param([Parameter(Mandatory)] [string] $Impresora, [Parameter(Mandatory)] [string] $Archivo, [int] $EsperaSegundos = 25)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RawPrinter {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public class DOCINFO { public string pDocName; public string pOutputFile; public string pDataType; }
  [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool OpenPrinter(string name, out IntPtr h, IntPtr d);
  [DllImport("winspool.drv", SetLastError = true)] public static extern bool ClosePrinter(IntPtr h);
  [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern int StartDocPrinter(IntPtr h, int level, [In] DOCINFO di);
  [DllImport("winspool.drv", SetLastError = true)] public static extern bool EndDocPrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError = true)] public static extern bool StartPagePrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError = true)] public static extern bool EndPagePrinter(IntPtr h);
  [DllImport("winspool.drv", SetLastError = true)] public static extern bool WritePrinter(IntPtr h, byte[] b, int n, out int w);
  public static int Enviar(string impresora, byte[] datos, string nombreDoc) {
    IntPtr h;
    if (!OpenPrinter(impresora, out h, IntPtr.Zero)) throw new Exception("No se encontró la impresora '" + impresora + "' (error " + Marshal.GetLastWin32Error() + ")");
    try {
      var di = new DOCINFO { pDocName = nombreDoc, pDataType = "RAW" };
      int trabajo = StartDocPrinter(h, 1, di);
      if (trabajo == 0) throw new Exception("Windows no aceptó el trabajo (error " + Marshal.GetLastWin32Error() + ")");
      StartPagePrinter(h);
      int escritos;
      bool ok = WritePrinter(h, datos, datos.Length, out escritos);
      EndPagePrinter(h);
      EndDocPrinter(h);
      if (!ok || escritos != datos.Length) throw new Exception("No se pudo enviar a la impresora (error " + Marshal.GetLastWin32Error() + ")");
      return trabajo;
    } finally { ClosePrinter(h); }
  }
}
"@

try {
  $datos = [System.IO.File]::ReadAllBytes($Archivo)
  $trabajo = [RawPrinter]::Enviar($Impresora, $datos, 'La Merced ' + [System.IO.Path]::GetFileNameWithoutExtension($Archivo))
} catch {
  [Console]::Error.WriteLine($_.Exception.Message); exit 1
}

# Esperar a que el trabajo salga de la cola de Windows.
$limite = (Get-Date).AddSeconds($EsperaSegundos)
while ((Get-Date) -lt $limite) {
  $j = Get-PrintJob -PrinterName $Impresora -ID $trabajo -ErrorAction SilentlyContinue
  if (-not $j) { exit 0 }
  if ("$($j.JobStatus)" -match 'Error|Offline|PaperOut|UserIntervention|Blocked') { break }
  Start-Sleep -Milliseconds 400
}
Remove-PrintJob -PrinterName $Impresora -ID $trabajo -ErrorAction SilentlyContinue
$estado = (Get-Printer -Name $Impresora -ErrorAction SilentlyContinue).PrinterStatus
[Console]::Error.WriteLine("La impresora no respondió (estado: $estado). Revisa que esté encendida, con papel y conectada.")
exit 2
