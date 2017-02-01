use v6;
use CSV::Parser;

# the output CSV from the Family Historian plugin must be saved as ANSI CSV

#------------------------------------------------------------------
# Standard locations for this User (perl 6)
#------------------------------------------------------------------
my $userprofile = %*ENV<USERPROFILE>;
my $googledrive = $userprofile ~ '/Google Drive/';
my $onedrive = $userprofile ~ '/OneDrive/';
my $desktop = $userprofile ~ '/Desktop/';
my $documents = $userprofile ~ '/Documents/';

my $fh     = open $onedrive ~ 'Family Historian Projects/Family/Public/Census and Residence.csv', :r;
my $parser = CSV::Parser.new( file_handle => $fh, contains_header_row => True );
my %data;

my @census;
my @residence;

# 29	RATCLIFFE	Margaret	CENS	31 March 1901

my $log = open 'report.txt', :w;

my $id = 0;
my $name = '';

until $fh.eof {
  %data = %($parser.get_line());
  if %data{'ID'} != $id {
    # a new person, so process the stored data if there is any
    if @census.elems > 0 {
      my %seen;
      my @aonly;
      %seen{@residence} = ();
      for @census -> $censusItem {
        push(@aonly, $censusItem) unless %seen{$censusItem}:exists;
      }
      @census = @aonly;
      # now we have removed all the residences that match census entries, so we
      # just output the remaining census entries
      if @census.elems > 0 {
        my $message = "$id $name missing residences for the following ";
        if @census.elems == 1 {
          $message ~= "census: ";
        } else {
          $message ~= "censuses: "
        }
        $message ~= join(', ', @census);
        $log.say($message);
      }
      @census = ();
      @residence = ();
    }
  }

  if %data{'Census/Residence'} eq 'CENS' {
    push @census, %data{'Date'};
  } else {
    push @residence, %data{'Date'};
  }
  $id = %data{'ID'};
  $name = %data{'Surname'} ~ ' ' ~ %data{'Given Names'};
}

$fh.close;
$log.close;
