/* Replaces a bundled keychain-fix tweak: dyld still finds a library of the same
   install name, but nothing in it runs. Built once; the engine rewrites the
   install name with its own Mach-O editor for each tweak it neutralises. */
void ipa_neutralised(void) {}
