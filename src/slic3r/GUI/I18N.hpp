#include <wx/string.h>
#include <wx/translation.h>
#include <wx/strconv.h>
#include <string>
#ifndef _
#define _(s)    	Slic3r::GUI::I18N::translate((s))
#define _L(s)    	Slic3r::GUI::I18N::translate((s))
#define _devL(s)	wxString((s))
#define _omitL(s)   ("")
#define _utf8(s)    Slic3r::GUI::I18N::translate_utf8((s))
#define _u8L(s)     Slic3r::GUI::I18N::translate_utf8((s))
#endif /* _ */

#ifndef _L_CONTEXT
#define _L_CONTEXT(s, ctx) 	 Slic3r::GUI::I18N::translate((s), (ctx))
#define _u8L_CONTEXT(s, ctx) Slic3r::GUI::I18N::translate_utf8((s), (ctx))
#endif /* _ */

#ifndef L
// !!! If you needed to translate some wxString,
// !!! please use _L(string)
// !!! _() - is a standard wxWidgets macro to translate
// !!! L() is used only for marking localizable string 
// !!! It will be used in "xgettext" to create a Locating Message Catalog.
#define L(s) s
#endif /* L */

#ifndef L_CONTEXT
#define L_CONTEXT(s, context) s
#endif /* L */

#ifndef _CHB
//! macro used to localization, return wxScopedCharBuffer
//! With wxConvUTF8 explicitly specify that the source string is already in UTF-8 encoding
#define _CHB(s) wxGetTranslation(wxString(s, wxConvUTF8)).utf8_str()
#endif /* _CHB */

#ifndef slic3r_GUI_I18N_hpp_
#define slic3r_GUI_I18N_hpp_

#include <wx/intl.h>
#include <wx/version.h>

namespace Slic3r { namespace GUI { 

namespace I18N {
	// Unified Slicer renamed the app in its English strings, and the catalogs still hold the
	// translations under the Orca wording. A message that is not translated and names the app is
	// looked up again under its Orca wording, and the name is put back in the translation. This
	// keeps the rename in one place instead of in every catalog. Defined in I18N.cpp.
	wxString keep_translation(const wxString &msgid, const wxString &translated, const wxString &context = wxEmptyString);
	inline wxString translate_one(const wxString &s) { return keep_translation(s, wxGetTranslation(s)); }

	inline wxString translate(const char         *s) { return translate_one(wxString(s, wxConvUTF8)); }
	inline wxString translate(const wchar_t      *s) { return translate_one(wxString(s)); }
	inline wxString translate(const std::string  &s) { return translate_one(wxString(s.c_str(), wxConvUTF8)); }
	inline wxString translate(const std::wstring &s) { return translate_one(wxString(s.c_str())); }
	inline wxString translate(const wxString     &s) { return translate_one(s); }

	inline wxString translate(const char         *s, const char 	    *plural, unsigned int n) { return wxGetTranslation(wxString(s, wxConvUTF8), wxString(plural, wxConvUTF8), n); }
	inline wxString translate(const wchar_t      *s, const wchar_t	    *plural, unsigned int n) { return wxGetTranslation(s, plural, n); }
	inline wxString translate(const std::string  &s, const std::string  &plural, unsigned int n) { return wxGetTranslation(wxString(s.c_str(), wxConvUTF8), wxString(plural.c_str(), wxConvUTF8), n); }
	inline wxString translate(const std::wstring &s, const std::wstring &plural, unsigned int n) { return wxGetTranslation(s.c_str(), plural.c_str(), n); }
	inline wxString translate(const wxString     &s, const wxString     &plural, unsigned int n) { return wxGetTranslation(s, plural, n); }

	inline std::string translate_utf8(const char         *s) { return translate(s).ToUTF8().data(); }
	inline std::string translate_utf8(const wchar_t      *s) { return translate(s).ToUTF8().data(); }
	inline std::string translate_utf8(const std::string  &s) { return translate(s).ToUTF8().data(); }
	inline std::string translate_utf8(const std::wstring &s) { return translate(s).ToUTF8().data(); }
	inline std::string translate_utf8(const wxString     &s) { return translate(s).ToUTF8().data(); }

	inline std::string translate_utf8(const char         *s, const char 	    *plural, unsigned int n) { return translate(s, plural, n).ToUTF8().data(); }
	inline std::string translate_utf8(const wchar_t      *s, const wchar_t	    *plural, unsigned int n) { return translate(s, plural, n).ToUTF8().data(); }
	inline std::string translate_utf8(const std::string  &s, const std::string  &plural, unsigned int n) { return translate(s, plural, n).ToUTF8().data(); }
	inline std::string translate_utf8(const std::wstring &s, const std::wstring &plural, unsigned int n) { return translate(s, plural, n).ToUTF8().data(); }
	inline std::string translate_utf8(const wxString     &s, const wxString     &plural, unsigned int n) { return translate(s, plural, n).ToUTF8().data(); }

	inline wxString translate_ctx(const wxString &s, const char *ctx)
	{
		const wxString context(ctx, wxConvUTF8);
		return keep_translation(s, wxGetTranslation(s, wxEmptyString, context), context);
	}

	inline wxString translate(const char *s, const char* ctx)         { return translate_ctx(wxString(s, wxConvUTF8), ctx); }
	inline wxString translate(const wchar_t *s, const char* ctx)      { return translate_ctx(wxString(s), ctx); }
	inline wxString translate(const std::string &s, const char* ctx)  { return translate_ctx(wxString(s.c_str(), wxConvUTF8), ctx); }
	inline wxString translate(const std::wstring &s, const char* ctx) { return translate_ctx(wxString(s.c_str()), ctx); }
	inline wxString translate(const wxString &s, const char* ctx)     { return translate_ctx(s, ctx); }

	inline std::string translate_utf8(const char *s, const char* ctx)         { return translate(s, ctx).ToUTF8().data(); }
	inline std::string translate_utf8(const wchar_t *s, const char* ctx)      { return translate(s, ctx).ToUTF8().data(); }
	inline std::string translate_utf8(const std::string &s, const char* ctx)  { return translate(s, ctx).ToUTF8().data(); }
	inline std::string translate_utf8(const std::wstring &s, const char* ctx) { return translate(s, ctx).ToUTF8().data(); }
	inline std::string translate_utf8(const wxString &s, const char* ctx)     { return translate(s, ctx).ToUTF8().data(); }

} // namespace I18N

// Return translated std::string as a wxString
wxString	L_str(const std::string &str);

} // namespace GUI
} // namespace Slic3r

// Macro to function both as a marker for xgettext and to actually perform the translation.
#ifndef _L_PLURAL
#define _L_PLURAL(s, plural, n) Slic3r::GUI::I18N::translate(s, plural, n)
#endif /* L */

#endif /* slic3r_GUI_I18N_hpp_ */
