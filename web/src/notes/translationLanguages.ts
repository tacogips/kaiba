/** Stable language names are also the values sent to the translation service. */
export const translationLanguages = [
  ['Arabic', 'العربية', 'ar'], ['Bengali', 'বাংলা', 'bn'], ['Bulgarian', 'Български', 'bg'],
  ['Burmese', 'မြန်မာ', 'my'], ['Catalan', 'Català', 'ca'], ['Chinese (Simplified)', '简体中文', 'zh zh-cn'],
  ['Chinese (Traditional)', '繁體中文', 'zh zh-tw'], ['Croatian', 'Hrvatski', 'hr'], ['Czech', 'Čeština', 'cs'],
  ['Danish', 'Dansk', 'da'], ['Dutch', 'Nederlands', 'nl'], ['English', 'English', 'en'],
  ['Estonian', 'Eesti', 'et'], ['Finnish', 'Suomi', 'fi'], ['French', 'Français', 'fr'],
  ['German', 'Deutsch', 'de'], ['Greek', 'Ελληνικά', 'el'], ['Gujarati', 'ગુજરાતી', 'gu'],
  ['Hebrew', 'עברית', 'he'], ['Hindi', 'हिन्दी', 'hi'], ['Hungarian', 'Magyar', 'hu'],
  ['Icelandic', 'Íslenska', 'is'], ['Indonesian', 'Bahasa Indonesia', 'id'], ['Irish', 'Gaeilge', 'ga'],
  ['Italian', 'Italiano', 'it'], ['Japanese', '日本語', 'ja'], ['Kannada', 'ಕನ್ನಡ', 'kn'],
  ['Khmer', 'ខ្មែរ', 'km'], ['Korean', '한국어', 'ko'], ['Lao', 'ລາວ', 'lo'],
  ['Latvian', 'Latviešu', 'lv'], ['Lithuanian', 'Lietuvių', 'lt'], ['Malay', 'Bahasa Melayu', 'ms'],
  ['Malayalam', 'മലയാളം', 'ml'], ['Marathi', 'मराठी', 'mr'], ['Nepali', 'नेपाली', 'ne'],
  ['Norwegian', 'Norsk', 'no nb nn'], ['Persian', 'فارسی', 'fa'], ['Polish', 'Polski', 'pl'],
  ['Portuguese', 'Português', 'pt'], ['Portuguese (Brazil)', 'Português do Brasil', 'pt-br'],
  ['Punjabi', 'ਪੰਜਾਬੀ', 'pa'], ['Romanian', 'Română', 'ro'], ['Russian', 'Русский', 'ru'],
  ['Serbian', 'Српски', 'sr'], ['Slovak', 'Slovenčina', 'sk'], ['Slovenian', 'Slovenščina', 'sl'],
  ['Spanish', 'Español', 'es'], ['Swahili', 'Kiswahili', 'sw'], ['Swedish', 'Svenska', 'sv'],
  ['Tagalog', 'Filipino', 'tl fil'], ['Tamil', 'தமிழ்', 'ta'], ['Telugu', 'తెలుగు', 'te'],
  ['Thai', 'ไทย', 'th'], ['Turkish', 'Türkçe', 'tr'], ['Ukrainian', 'Українська', 'uk'],
  ['Urdu', 'اردو', 'ur'], ['Vietnamese', 'Tiếng Việt', 'vi'], ['Welsh', 'Cymraeg', 'cy'],
].map(([name, nativeName, codes]) => ({ name: name!, nativeName: nativeName!, codes: codes!.split(' ') }))

export function matchingTranslationLanguages(prefix: string) {
  const query = prefix.trim().toLocaleLowerCase()
  return translationLanguages.filter((language) =>
    [language.name, language.nativeName, ...language.codes].some((value) => value.toLocaleLowerCase().startsWith(query)))
}
