use Modern::Perl;
use Win32::Clipboard;

my $clip = Win32::Clipboard();

while ($clip->WaitForChange()) {
    if ( $clip->IsText() ) {
        my $contents = $clip->GetText();
        $contents =~ s/\t+/ /msgx;
        $contents =~ s/\n+/ /msgx;
        $contents =~ s/\s+/ /msgx;
        $clip->Set($contents);
        say "$contents";
        $clip->WaitForChange(5);
    }
}
