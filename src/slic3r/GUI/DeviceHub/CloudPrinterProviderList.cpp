#include "BuiltinCloudProviders.hpp"
#include "CloudPrinterProvider.hpp"
#include "LocalPrintersProvider.hpp"

#include <memory>
#include <wx/colour.h>

#include "slic3r/Utils/CloudProvider.hpp"

namespace Slic3r { namespace GUI {

// The services on the Device tab's rail, in rail order. One line per service, so each
// integration replaces only its own line.
void CloudPrinterProviders::register_builtin()
{
    static bool registered = false;
    if (registered)
        return;
    registered = true;

    add(std::make_shared<BambuCloudProvider>());
    // Elegoo: Elegoo cloud account (native) plus the CC2 LAN agent for printers on the local network.
    add(std::make_shared<ElegooCloudProvider>());
    // Creality: cloud agent "creality_cloud" with account "creality".
    add(std::make_shared<CrealityCloudProvider>());
    // Snapmaker: cloud agent "snapmaker_cloud" with account "snapmaker" (Snapmaker ID).
    add(std::make_shared<PrinterAgentCloudProvider>("snapmaker", "Snapmaker", 35, "snapmaker_cloud", "snapmaker",
                                                    wxColour("#0F8BD6")));
    // Markforged: Eiger cloud agent "markforged_eiger", API keys.
    add(std::make_shared<MarkforgedCloudProvider>());
    // USB & LAN: print-host presets (OctoPrint, Moonraker, ...) and USB printers no service claims.
    add(std::make_shared<LocalPrintersProvider>());
}

}} // namespace Slic3r::GUI
