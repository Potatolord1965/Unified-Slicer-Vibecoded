#include "I18N.hpp"
#include <wx/string.h>
#include <string>
#include <wx/translation.h>
#include <wx/strconv.h>
#include <wx/defs.h>
#include "libslic3r_version.h"

namespace Slic3r { namespace GUI { 

wxString L_str(const std::string &str)
{
	//! Explicitly specify that the source string is already in UTF-8 encoding
	return I18N::translate(str);
}

namespace I18N {

wxString keep_translation(const wxString &msgid, const wxString &translated, const wxString &context)
{
	static const wxString app_name = wxString::FromUTF8(SLIC3R_APP_NAME);
	// Translated already, or nothing to look up again.
	if (translated != msgid || msgid.Find(app_name) == wxNOT_FOUND)
		return translated;
	// The upstream wordings of the app name, most specific first.
	for (const wxString &orca : {wxString("Orca Slicer"), wxString("OrcaSlicer"), wxString("Orca")}) {
		wxString original = msgid;
		original.Replace(app_name, orca);
		const wxString found = context.empty() ? wxGetTranslation(original) : wxGetTranslation(original, wxEmptyString, context);
		if (found != original) {
			wxString out = found;
			out.Replace(orca, app_name);
			return out;
		}
	}
	return translated;
}

} // namespace I18N

} }
