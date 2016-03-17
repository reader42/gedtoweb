#===============================================================================
#
#         FILE: GedToWeb.pl
#
#        USAGE: ./GedToWeb.pl
#
#  DESCRIPTION: Read a GEDCOM file and generate a useful website
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Pete Barlow (PB), langbard@gmail.com
# ORGANIZATION:
#      VERSION: 1.0
#      CREATED: 19/06/2015 12:48:25
#     REVISION: 03/03/2016 to use bootstrap
#               09/03/2016 beta testing phase
#===============================================================================

use Modern::Perl;
use Gedcom;
use Template;
use Data::Dumper;
use Log::Log4perl qw(get_logger :levels);
use Encode qw/encode decode/;
use File::Copy;
use Tie::IxHash;
use Lingua::EN::Inflect qw(ORD);

#-------------------------------------------------------------------------------
#  Stats counters
#-------------------------------------------------------------------------------

my $totalPeople   = 0;
my $skippedLiving = 0;
my $skippedNoWeb  = 0;
my $skippedNoFlag = 0;
my $addedPeople   = 0;

#------------------------------------------------------------------
# Standard locations for this User (perl 5)
#------------------------------------------------------------------
my $userprofile = $ENV{USERPROFILE};
my $dropbox     = $userprofile . '/Dropbox/';
my $googledrive = $userprofile . '/Google Drive/';
my $onedrive    = $userprofile . '/OneDrive/';
my $desktop     = $userprofile . '/Desktop/';
my $documents   = $userprofile . '/Documents/';

#-------------------------------------------------------------------------------
#  Set up logging
#-------------------------------------------------------------------------------
my $conf = q(
log4perl.rootLogger=DEBUG, AppInfo, AppWarn, AppError
# Filter to match level ERROR
log4perl.filter.MatchError = Log::Log4perl::Filter::LevelMatch
log4perl.filter.MatchError.LevelToMatch = ERROR
log4perl.filter.MatchError.AcceptOnMatch = true
# Filter to match level WARN
log4perl.filter.MatchWarn = Log::Log4perl::Filter::LevelMatch
log4perl.filter.MatchWarn.LevelToMatch = WARN
log4perl.filter.MatchWarn.AcceptOnMatch = true
# Filter to match level INFO
log4perl.filter.MatchInfo = Log::Log4perl::Filter::LevelMatch
log4perl.filter.MatchInfo.LevelToMatch = INFO
log4perl.filter.MatchInfo.AcceptOnMatch = true
# Error appender messages go to the screen
log4perl.appender.AppError = Log::Log4perl::Appender::Screen
log4perl.appender.AppError.layout = SimpleLayout
log4perl.appender.AppError.Filter = MatchError
# Warn appender
log4perl.appender.AppWarn = Log::Log4perl::Appender::File
log4perl.appender.AppWarn.filename = log.txt
log4perl.appender.AppWarn.mode = overwrite
log4perl.appender.AppWarn.layout = SimpleLayout
log4perl.appender.AppWarn.Filter = MatchWarn
# Info appender
log4perl.appender.AppInfo = Log::Log4perl::Appender::File
log4perl.appender.AppInfo.filename = log.txt
log4perl.appender.AppInfo.mode = overwrite
log4perl.appender.AppInfo.layout = SimpleLayout
log4perl.appender.AppInfo.Filter = MatchInfo);
Log::Log4perl::init( \$conf );
my $logger = Log::Log4perl::get_logger("");

my $fhbase = 'Family Historian Projects/Family/';

my $template = Template->new(
  {
    INCLUDE_PATH => 'Templates',
    PRE_CHOMP    => 1,
    POST_CHOMP   => 1
  }
);
my $outDir = $onedrive . $fhbase . 'Public/FH Website/';

#-------------------------------------------------------------------------------
#  Get the GEDCOM and turn it into a local ASCII version, note that the input
#  file is UTF-16 little-endian
#-------------------------------------------------------------------------------

my $IN_file_name =
  $onedrive . $fhbase . 'Family.fh_data/Family.ged';    # input file name

open my $IN, '<encoding(UTF-16LE)', $IN_file_name
  or $logger->logdie("$0 : failed to open  input file '$IN_file_name' : $!");

my $OUT_file_name = 'Family.ged';                       # output file name

open my $OUT, '>:encoding(UTF-8)', $OUT_file_name
  or $logger->logdie("$0 : failed to open  output file '$OUT_file_name' : $!");

my $skipping = 0;
while (<$IN>) {
  chomp;
  chop;    # needed because UTF-16LE?
  if (m/^0 \@P\d+\@ _PLAC/) {
    $skipping = 1;
  }
  if (m/^0 TRLR/) {
    $skipping = 0;
  }
  say $OUT $_ unless $skipping;
}

close $OUT
  or
  $logger->logerror("$0 : failed to close output file '$OUT_file_name' : $!");

close $IN
  or $logger->logerror("$0 : failed to close input file '$IN_file_name' : $!");

my $ged = Gedcom->new( gedcom_file => 'Family.ged' );

#-------------------------------------------------------------------------------
#  Clean up the output directory and move in the fixed files
#-------------------------------------------------------------------------------

foreach my $htmFile ( glob qq("${outDir}*.htm") ) {
  unlink $htmFile;
}

my $RPT_file_name = $outDir . 'index.htm';    # output file name

open my $RPT, '>', $RPT_file_name
  or $logger->logdie("$0 : failed to open output file '$RPT_file_name' : $!");
my $vars = {};
$template->process( 'index.tt', $vars, $RPT )
  || $logger->logdie( $template->error() );
close $RPT
  or
  $logger->logerror("$0 : failed to close output file '$RPT_file_name' : $!");

$RPT_file_name = $outDir . 'todo.htm';        # output file name

open $RPT, '>', $RPT_file_name
  or $logger->logdie("$0 : failed to open output file '$RPT_file_name' : $!");
$vars = {};
$template->process( 'todo.tt', $vars, $RPT )
  || $logger->logdie( $template->error() );
close $RPT
  or
  $logger->logerror("$0 : failed to close output file '$RPT_file_name' : $!");

$RPT_file_name = $outDir . 'about.htm';       # output file name

open $RPT, '>', $RPT_file_name
  or $logger->logdie("$0 : failed to open output file '$RPT_file_name' : $!");
$vars = {};
$template->process( 'about.tt', $vars, $RPT )
  || $logger->logdie( $template->error() );
close $RPT
  or
  $logger->logerror("$0 : failed to close output file '$RPT_file_name' : $!");

#-------------------------------------------------------------------------------
#  Hash to store people and used to construct the index, page number and page
#  counter
#-------------------------------------------------------------------------------
my %people;

my $page      = 1;
my $pageCount = 0;
my $pageLimit = 40;

# Global variables for relationship calculations

my @foundDownTrace = ();
my $found          = 0;
my $weird          = 0;
my @downTrace      = ();
tie my %currentList, "Tie::IxHash";
my %seenHashUp;
my %seenHashDown;

# shows that the person found is a spouse of an ancestor
my $spouseFlag;

# cumulative count of searches performed
my $searchesPerformed = 0;
my $DEBUGGING         = 0;

#-------------------------------------------------------------------------------
#  Build the list of people to be processed by adding their references to the
#  list and also their details to the people index.
#-------------------------------------------------------------------------------
my @references = qw/I125 I129 I191 I1319 I277 I159 I192 I276 I170 I130 I58/;

#-----------------------------------------------------------------------------
#  Turn on debugging for nominated person I???
#-----------------------------------------------------------------------------
my $debugPerson = 'I1661';

while ( my $ref = shift @references ) {
  my $person = $ged->get_individual($ref);

#-------------------------------------------------------------------------------
# Store details for index and add to processing queue if not present: person,
# father, mother, spouses, children, witnesses to events and marriages
#-------------------------------------------------------------------------------
  checkAdd($person);
  if ( $person->father ) {
    checkAdd( $person->father );
  }
  if ( $person->mother ) {
    checkAdd( $person->mother );
  }
  foreach my $spouse ( $person->spouse ) {
    checkAdd($spouse);
  }
  foreach my $child ( $person->children ) {
    checkAdd($child);
  }

  if ( $person->baptism ) {
    if ( $person->baptism->shared ) {
      my @shared = $person->baptism->record('shared');
      foreach my $witness (@shared) {
        $witness = $witness->get_value;
        $witness = $ged->get_individual($witness);
        checkAdd($witness);
      }
    }
  }

#-------------------------------------------------------------------------------
#  Handle switching to a new page
#-------------------------------------------------------------------------------
  $pageCount++;
  if ( $pageCount >= $pageLimit ) {
    $page++;
    $pageCount = 0;
  }
}

my $currentPage = 1;
$page          = 1;
$RPT_file_name = $outDir . 'P0001.htm';    # output file name

open $RPT, '>', $RPT_file_name
  or $logger->logdie("$0 : failed to open output file '$RPT_file_name' : $!");
$vars = { page => $page, notBlank => \&notBlank };
$template->process( 'personpagehead.tt', $vars, $RPT )
  || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
# Process the people index in page order
#-------------------------------------------------------------------------------

foreach my $key ( sort { $people{$a} cmp $people{$b} } keys %people ) {

  my $person = $people{$key};

  # get the page number
  $person =~ s/\[(\d+)\] //;
  $page = $1;

  # and set the reference
  my $ref = $key;

#-------------------------------------------------------------------------------
#  Handle change of page
#-------------------------------------------------------------------------------
  if ( $page != $currentPage ) {
    if ( $currentPage != 0 ) {
      $template->process( 'personpagefoot.tt', undef, $RPT )
        || $logger->logdie( $template->error() );
      close $RPT
        or $logger->logerror(
        "$0 : failed to close output file '$RPT_file_name' : $!");
    }
    $currentPage = $page;
    my $RPT_file_name = $outDir . 'P' . $page . '.htm';    # output file name

    open $RPT, '>', $RPT_file_name
      or
      $logger->logdie("$0 : failed to open  output file '$RPT_file_name' : $!");
    my $vars = { page => $page, notBlank => \&notBlank };
    $template->process( 'personpagehead.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );
  }

  $person = $ged->get_individual($ref);

#-------------------------------------------------------------------------------
#  Only process people who are not living and have the Web flag
#-------------------------------------------------------------------------------
  my $flag = $person->record('flags');
  if ($flag) {
    if ( !$person->flags->web ) {
      removeIndex($person);
      $skippedNoWeb++;

# $logger->info( $person->cased_name, ' not processed because Web flag not set' );
      next;
    }
    if ( $person->flags->living ) {
      removeIndex($person);
      $skippedLiving++;

# $logger->info( $person->cased_name, ' not processed because Living flag set' );
      next;
    }

#-------------------------------------------------------------------------------
#  Basic details of the person and their father and mother and add parent to
#  list for processing
#-------------------------------------------------------------------------------

    $vars = {
      person       => basicDetails($person),
      father       => basicDetails( $person->father ),
      mother       => basicDetails( $person->mother ),
      notBlank     => \&notBlank,
      indiref      => $ref,
      relationship => calculateRelationship($ref)
    };

    $template->process( 'indihead.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );
    $addedPeople++;

#-------------------------------------------------------------------------------
#  Details of their events, eventCount also records marriages and censuses
#-------------------------------------------------------------------------------
    my @events;
    my $eventCount = 0;

#-------------------------------------------------------------------------------
#  Birth, etc.
#-------------------------------------------------------------------------------
    if ( $person->birth ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was born', 'on', $person->birth );
    }
    if ( $person->baptism ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was baptised', 'on', $person->baptism );
    }
    if ( $person->christening ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was christened',
        'on', $person->christening );
    }

#-------------------------------------------------------------------------------
#  Later religious events
#-------------------------------------------------------------------------------
    if ( $person->confirmation ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was confirmed',
        'on', $person->confirmation );
    }
    if ( $person->first_communion ) {
      $eventCount++;
      push @events,
        eventDetails(
        $person->sex, 'recieved first communion',
        'on',         $person->first_communion
        );
    }
    if ( $person->marriage_bann ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'had banns read',
        'on', $person->marriage_bann );
    }

#-------------------------------------------------------------------------------
#  Occupations
#-------------------------------------------------------------------------------
    my @occs = $person->record('occupation');
    foreach my $occ (@occs) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was ' . $occ->get_value, 'in', $occ );
    }

#-------------------------------------------------------------------------------
#  Death, etc.
#-------------------------------------------------------------------------------
    if ( $person->death ) {
      $eventCount++;
      push @events, eventDetails( $person->sex, 'died', 'on', $person->death );
    }
    if ( $person->burial ) {
      $eventCount++;
      push @events,
        eventDetails( $person->sex, 'was buried', 'on', $person->burial );
    }

    $vars = {
      events   => \@events,
      notBlank => \&notBlank
    };
    $template->process( 'events.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
#  Census
#-------------------------------------------------------------------------------
    my @censuses;
    my @cenevents = $person->record('census');
    foreach my $census (@cenevents) {
      $eventCount++;
      push @censuses, censusDetails($census);
    }
    $vars = {
      censuses => \@censuses,
      notBlank => \&notBlank
    };
    $template->process( 'censuses.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
#  Marriages
#-------------------------------------------------------------------------------
    my @marriages;
    my @families = $person->record('family_spouse');
    foreach my $family (@families) {
      $eventCount++;
      push @marriages, marriageDetails($family);
    }
    $vars = {
      marriages => \@marriages,
      notBlank  => \&notBlank
    };
    $template->process( 'marriages.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
#  Details of their children by spouse, note that for illegitimate children
#  they will not have both a mother xref and a father xref
#-------------------------------------------------------------------------------

    my @children;
    my @bastards;

    foreach my $spouse ( $person->spouse ) {
      foreach my $child ( $person->children ) {
        my $childParent = '';
        if ( uc( $spouse->sex ) eq 'M' ) {
          if ( $child->father ) {
            $childParent = $child->father->xref;
          }
        } else {
          if ( $child->mother ) {
            $childParent = $child->mother->xref;
          }
        }
        if ( $childParent eq $spouse->xref ) {
          debugPrint( $ref, "Child", $child->given_names, $child->xref,
            "added to spouse",
            $spouse->given_names, $spouse->xref )
            if $DEBUGGING;
          push @children, basicDetails($child);
        } else {

          # Natural children have no recorded father or mother
          if ( !$child->father || !$child->mother ) {
            debugPrint( $ref, "Natural Child",
              $child->given_names, $child->xref, "added" )
              if $DEBUGGING;
            push @bastards, basicDetails($child);
          }
        }
      }

      $vars = {
        spouse   => basicDetails($spouse),
        children => \@children,
        notBlank => \&notBlank
      };
      $template->process( 'children.tt', $vars, $RPT )
        || $logger->logdie( $template->error() );
      @children = ();
    }
    if (@bastards) {
      $vars = {
        spouse   => { surname => 'Unknown', page => undef },
        children => \@bastards,
        notBlank => \&notBlank
      };
      $template->process( 'children.tt', $vars, $RPT )
        || $logger->logdie( $template->error() );
      @bastards = ();
    }
    $template->process( 'indifoot.tt', $vars, $RPT )
      || $logger->logdie( $template->error() );
    if ( $eventCount == 0 ) {
      $logger->warn( $person->cased_name . ' ' . $ref . ' has no events' );
    }
  } else {
    removeIndex($person);

 # $logger->info( $person->cased_name . ' not processed because no flags set' );
    $skippedNoFlag++;
  }
}
$template->process( 'personpagefoot.tt', undef, $RPT )
  || $logger->logdie( $template->error() );
close $RPT
  or
  $logger->logerror("$0 : failed to close output file '$RPT_file_name' : $!");

#-------------------------------------------------------------------------------
#  Open the master surname index
#-------------------------------------------------------------------------------
my $INDEX_file_name = $outDir . 'surname_index.htm';    # output file name

open my $INDEX, '>', $INDEX_file_name
  or $logger->logdie("$0 : failed to open output file '$INDEX_file_name' : $!");
$template->process( 'indexpagehead.tt', undef, $INDEX )
  || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
#  Open a new file for Unknown surnames
#-------------------------------------------------------------------------------
my $lastName      = '';
my $lastNameCount = 0;

my $SURNAME_file_name = $outDir . 'Unknown.htm';    # output file name

open my $SURNAME, '>', $SURNAME_file_name
  or
  $logger->logdie("$0 : failed to open output file '$SURNAME_file_name' : $!");
$vars = { surname => 'Unknown' };
$template->process( 'surnamepagehead.tt', $vars, $SURNAME )
  || $logger->logdie( $template->error() );

foreach my $key ( sort indexSort keys %people ) {

  my $person = $people{$key};

  $person =~ m/^
                \[(?<page>\d+)\]
                \s
                (?<surname>[[:upper:]]*)
                \s(?<givennames>.*?)
                \s
                \#(?<dates>.*)\#
                /x;
  my $page       = $+{page};
  my $dates      = $+{dates};
  my $surname    = $+{surname};
  my $givennames = $+{givennames};
  if ( !$surname ) {
    $surname = '';
  }

#-------------------------------------------------------------------------------
#  On change of surname
#-------------------------------------------------------------------------------
  if ( $surname ne $lastName ) {

#-------------------------------------------------------------------------------
#  Close the old file
#-------------------------------------------------------------------------------
    $template->process( 'surnamepagefoot.tt', undef, $SURNAME )
      || $logger->logdie( $template->error() );

    close $SURNAME
      or $logger->logerror(
      "$0 : failed to close output file '$SURNAME_file_name' : $!");

#-------------------------------------------------------------------------------
#  Write the surname and the count to the surname index
#-------------------------------------------------------------------------------
    if ( $lastName eq '' ) {
      $lastName = 'Unknown';
    }
    $vars = {
      href      => $SURNAME_file_name,
      surname   => $lastName,
      namecount => $lastNameCount,
    };
    $template->process( 'indexpageentry.tt', $vars, $INDEX )
      || $logger->logdie( $template->error() );

#-------------------------------------------------------------------------------
#  Open a new file
#-------------------------------------------------------------------------------
    $SURNAME_file_name = $outDir . $surname . '.htm';    # output file name
    open $SURNAME, '>', $SURNAME_file_name
      or $logger->logdie("$0 : failed to open output file '$SURNAME' : $!");
    $vars = { surname => $surname };
    $template->process( 'surnamepagehead.tt', $vars, $SURNAME )
      || $logger->logdie( $template->error() );

    $lastName      = $surname;
    $lastNameCount = 0;
  }
  $lastNameCount++;

  $vars = {
    givennames => $givennames,
    dates      => $dates,
    href       => 'P' . $page . '.htm#' . $key,
  };
  $template->process( 'surnamepageentry.tt', $vars, $SURNAME )
    || $logger->logdie( $template->error() );

}
$template->process( 'surnamepagefoot.tt', undef, $SURNAME )
  || $logger->logdie( $template->error() );

close $SURNAME
  or $logger->logerror(
  "$0 : failed to close output file '$SURNAME_file_name' : $!");

#-------------------------------------------------------------------------------
#  Write the final surname and the count to the surname index
#-------------------------------------------------------------------------------
$vars = {
  href      => $SURNAME_file_name,
  surname   => $lastName,
  namecount => $lastNameCount,
};
$template->process( 'indexpageentry.tt', $vars, $INDEX )
  || $logger->logdie( $template->error() );
$template->process( 'indexpagefoot.tt', undef, $INDEX )
  || $logger->logdie( $template->error() );

close $INDEX
  or
  $logger->logerror("$0 : failed to close output file '$INDEX_file_name' : $!");

say "Total people processed       $totalPeople";
say "Skipped because Living       $skippedLiving";
say "Skipped because No Web Flag  $skippedNoWeb";
say "Skipped because No Flag      $skippedNoFlag";
say "Added to web site            $addedPeople";

#===  FUNCTION  ================================================================
#         NAME: basicDetails
#      PURPOSE:
#   PARAMETERS: ????
#      RETURNS: a reference to a hash containing the basic details of the person
#  DESCRIPTION: ????
#       THROWS: no exceptions
#     COMMENTS: none
#     SEE ALSO: n/a
#===============================================================================

sub basicDetails {
  my $person = shift;
  my %details;
  if ($person) {
    $details{ref} = $person->xref;
    my $page;
    if ( exists $people{ $person->xref } ) {
      ( $page = $people{ $person->xref } ) =~ s/\[(\d+)\].*/$1/;
    } else {
      $page = undef;
    }
    $details{page}       = $page;
    $details{givennames} = $person->given_names;
    $details{surname}    = $person->surname;

#-------------------------------------------------------------------------------
# Remove page for living persons to stop invalid links being produced, this is
# needed because we might not have processed them and removed them from the index
#-------------------------------------------------------------------------------
    if ( $person->flags ) {
      if ( $person->flags->living ) {
        $details{page} = undef;
      }
    }

#-------------------------------------------------------------------------------
#  Check for unknowns and provide birth death details
#-------------------------------------------------------------------------------
    if ( ( !$details{surname} ) && ( !$details{givennames} ) ) {
      $details{surname} = "Unknown";
      $details{page}    = undef;
    }
    if ( $person->birth ) {
      if ( $person->birth eq "Y" ) {
        $details{born} = 'Unknown date';
      } else {
        $details{born} = fixDate( $person->birth->get_value('date') );
      }
    }
    if ( $person->death ) {
      if ( $person->death eq "Y" ) {
        $details{born} = 'Unknown date';
      } else {
        $details{died} = fixDate( $person->death->get_value('date') );
      }
    }
  }
  return \%details;
}

#===  FUNCTION  ================================================================
#         NAME: indexDetails
#      PURPOSE:
#   PARAMETERS: ????
#      RETURNS: ????
#  DESCRIPTION: ????
#       THROWS: no exceptions
#     COMMENTS: none
#     SEE ALSO: n/a
#===============================================================================

sub indexDetails {
  my $person  = shift;
  my $details = '';
  $details .= uc( $person->surname ) . ' ';
  $details .= $person->given_names . ' ';
  $details .= '#';
  if ( $person->birth ) {
    if ( $person->birth eq "Y" ) {
      $details .= 'Unknown date - ';
    } else {
      $details .= fixDate( $person->birth->get_value('date') ) . ' - ';
    }
  }
  if ( $person->death ) {
    if ( $person->death eq "Y" ) {
      $details .= 'Unknown date';
    } else {
      $details .= fixDate( $person->death->get_value('date') );
    }
  }
  $details .= '#';
  return $details;
}

sub removeIndex {
  my $person = shift;
  delete( $people{ $person->xref } );
  return;
}

#===  FUNCTION  ================================================================
#         NAME: eventDetails
#      PURPOSE:
#   PARAMETERS: ????
#      RETURNS: ????
#  DESCRIPTION: ????
#       THROWS: no exceptions
#     COMMENTS: none
#     SEE ALSO: n/a
#===============================================================================

sub eventDetails {
  my ( $sex, $verb, $inon, $event ) = @_;
  my %eventDetails;
  $eventDetails{sex}  = $sex;
  $eventDetails{verb} = $verb;
  if ($event) {
    if ( $event eq 'Y' ) {
      $eventDetails{date} = 'Unknown date';
    } else {
      if ( $event->get_value('date') ) {
        if ( $event->get_value('date') =~ /^BET|^ABT|^BEF|^AFT|^CAL/ ) {
          $eventDetails{date} = fixDate( $event->get_value('date') );
        } else {

          # a date like Oct 1886 or 1886 should be 'in'
          # a date like 14 Jan 1886 should be 'on'
          if ( $event->get_value('date') !~ /^\d{1,2}\s+/ ) {
            $eventDetails{date} =
              "in " . fixDate( $event->get_value('date') );
          } else {
            $eventDetails{date} =
              "$inon " . fixDate( $event->get_value('date') );
          }
        }
      }
      $eventDetails{place} = eventPlace($event);
      if ( $event->shared ) {
        my @witnesses = ();
        my @shared    = $event->record('shared');
        foreach my $witness (@shared) {
          $witness = $witness->get_value;
          $witness = $ged->get_individual($witness);
          push @witnesses, basicDetails($witness);
        }
        $eventDetails{witnesses} = \@witnesses;
      }
    }
  }
  return \%eventDetails;
}

sub eventPlace {
  my $event  = shift;
  my $phrase = '';
  my $inat   = '';
  if ( $event eq 'Y' ) {
    $phrase = 'at an unknown place';
  } else {
    if ( $event->get_value('address') ) {
      $phrase .= $event->get_value('address') . ', ';
      $inat = 'at ';
    }
    if ( $event->get_value('place') ) {
      $phrase .= $event->get_value('place');
      if ( !$inat ) {
        $inat = 'in ';
      }
    }
  }
  return $inat . $phrase;
}

sub marriageDetails {
  my $family = shift;
  my %marriage;
  if ( $family->husband ) {
    $marriage{husband} = basicDetails( $family->husband );
  } else {
    return \%marriage;
  }
  if ( $family->wife ) {
    $marriage{wife} = basicDetails( $family->wife );
  } else {
    return \%marriage;
  }
  if ( $family->marriage ) {
    $marriage{date} = fixDate( $family->marriage->get_value('date') );
    my $place = '';
    if ( $family->marriage->get_value('address') ) {
      $place .= $family->marriage->get_value('address') . ', ';
    }
    if ( $family->marriage->get_value('place') ) {
      $place .= $family->marriage->get_value('place');
    }
    $marriage{place} = $place;
    if ( $family->marriage->shared ) {
      my @witnesses = ();
      my @shared    = $family->marriage->record('shared');
      foreach my $witness (@shared) {
        $witness = $witness->get_value;
        $witness = $ged->get_individual($witness);
        push @witnesses, basicDetails($witness);
      }
      $marriage{witnesses} = \@witnesses;
    }
  }
  return \%marriage;
}

sub censusDetails {
  my $census = shift;
  my %details;
  $details{date} = fixDate( $census->get_value('date') );
  my $place = '';
  if ( $census->get_value('address') ) {
    $place .= $census->get_value('address') . ', ';
  }
  if ( $census->get_value('place') ) {
    $place .= $census->get_value('place');
  }
  $details{place} = $place;
  $details{age}   = $census->get_value('age');
  return \%details;
}

sub fixDate {
  my $date = shift;
  $date = "" unless $date;
  $date =~ s/BET\b/between/;
  $date =~ s/BEF\b/before/;
  $date =~ s/AFT\b/after/;
  $date =~ s/ABT\b/about/;
  $date =~ s/CAL\b/(calculated)/;
  $date =~ s/AND\b/and/;
  $date =~
s/(JAN\b|FEB\b|MAR\b|APR\b|MAY\b|JUN\b|JUL\b|AUG\b|SEP\b|OCT\b|NOV\b|DEC\b)/ucfirst(lc($1))/e;
  return $date;
}

sub checkAdd {
  my $person = shift;
  if ( !$person ) {
    return;
  }
  my $xref = $person->xref;

#-------------------------------------------------------------------------------
#  First check to see if they are already due to be processed
#-------------------------------------------------------------------------------
  if ( exists $people{$xref} ) {
    return;
  }

#-------------------------------------------------------------------------------
# Store details for index
#-------------------------------------------------------------------------------
  $people{$xref} =
    '[' . sprintf( '%04s', $page ) . '] ' . indexDetails($person);

#-------------------------------------------------------------------------------
#  Then check to see if they are already on the build list
#-------------------------------------------------------------------------------
  foreach my $ref (@references) {
    if ( $ref eq $xref ) {
      return;
    }
  }
  push @references, $xref;
  $totalPeople++;
  return;
}

sub indexSort {

#===  FUNCTION  ================================================================
#         NAME: indexSort
#      PURPOSE: Just sort on names
#   PARAMETERS: ????
#      RETURNS: ????
#  DESCRIPTION: ????
#       THROWS: no exceptions
#     COMMENTS: none
#     SEE ALSO: n/a
#===============================================================================
  my $name1 = $people{$a};
  my $name2 = $people{$b};
  $name1 =~ s/\[\d+\] //;
  $name2 =~ s/\[\d+\] //;
  $name1 =~ s/#.*#//;
  $name2 =~ s/#.*#//;
  return $name1 cmp $name2;
}

sub notBlank {

#===  FUNCTION  ================================================================
#         NAME: notBlank
#      PURPOSE: Used to suppress output where data are unknown
#   PARAMETERS: ????
#      RETURNS: ????
#  DESCRIPTION: ????
#       THROWS: no exceptions
#     COMMENTS: Note that spacing is the responsibility of the caller
#     SEE ALSO: n/a
#===============================================================================

  my $text = shift;
  my $item = shift;

  if ($item) {
    return $text . $item;
  }
  return;
}

sub calculateRelationship {
  my $testID = shift;

  @foundDownTrace = ();
  $found          = 0;
  @downTrace      = ();
  %currentList    = ();
  %seenHashUp     = ();
  %seenHashDown   = ();
  my $lastSearches = 0;

  initLevel('I1');
  while ( !$found ) {
    foreach my $indi ( keys %currentList ) {
      searchDown( $indi, $testID, 0 );

      last if $found;
    }
    last if $found;
    debugPrint("Adding next level") if $DEBUGGING;
    if ( $searchesPerformed > $lastSearches ) {
      $lastSearches = $searchesPerformed;
    } else {
      return "";
    }
    nextLevelUp();
  }
  my ( $minDepth, $maxDepth ) = addFound();
  printLevel($minDepth) if $DEBUGGING;
  my $difference = 0 - $minDepth;
  return nameRelationship( $testID, $maxDepth, $difference );
}

sub nameRelationship {
  my $testID     = shift;
  my $maxDepth   = shift;
  my $difference = shift;
  my $prefix     = '';
  my $relation;

  debugPrint( "Maxdepth", $maxDepth, 'Difference', $difference ) if $DEBUGGING;

  if ( $maxDepth == 0 ) {

    # (Grand) Son and Daughter
    $prefix = 'Great ' x ( $difference - 1 );
    $relation = sexID( $testID, 'Son', 'Daughter' );
  } elsif ( $maxDepth == -1 * $difference ) {

    # (Great) (Grand) Father and Mother
    $prefix = 'Great ' x ( $maxDepth - 2 );
    if ( $maxDepth > 1 ) {
      $relation = sexID( $testID, 'Grand Father', 'Grand Mother' );
    } else {
      $relation = sexID( $testID, 'Father', 'Mother' );
    }
  } elsif ( $maxDepth == 1 ) {

    # Sister/Brother or (Great) Nephew/Niece
    if ( $difference > 0 ) {
      $prefix = 'Great ' x ( $difference - 1 );
      $relation = sexID( $testID, 'Nephew', 'Niece' );
    } else {
      if ($spouseFlag) {
        $relation = sexID( $testID, 'Husband of Sister', 'Wife of Brother' );
      } else {
        $relation = sexID( $testID, 'Brother', 'Sister' );
      }
    }
  } elsif ( ( $maxDepth + $difference ) == 1 ) {

    # (Great) Uncle/Aunt
    $prefix = 'Great ' x ( $maxDepth - 2 );
    if ($spouseFlag) {
      $prefix   = sexID( $testID, 'Husband of ', 'Wife of ' ) . $prefix;
      $relation = sexID( $testID, 'Aunt',        'Uncle' );
    } else {
      $relation = sexID( $testID, 'Uncle', 'Aunt' );
    }
  } elsif ( $difference == 0 ) {

    # (nth) Cousin
    $prefix   = ORD( $maxDepth - 1 ) . ' ';
    $relation = 'Cousin';
  } elsif ( $difference > 0 ) {

    # (nth) Cousin m times removed
    $prefix   = ORD( $maxDepth - $difference ) . ' ';
    $relation = 'Cousin ' . abs($difference) . ' times removed';
  } else {

    # (nth) Cousin m times removed
    $prefix   = ORD( $maxDepth + $difference - 1 ) . ' ';
    $relation = 'Cousin ' . abs($difference) . ' times removed';
  }
  # fix n times to be better English
  if ($relation =~ / times /) {
    $relation =~ s/1 times/once/;
    $relation =~ s/2 times/twice/;
    $relation =~ s/3 times/thrice/;
  }
  return $prefix . $relation;
}

sub searchDown {

  #------------------------------------------------------------------
  # perform a depth first traversal of the tree rooted at $ref
  #------------------------------------------------------------------

  my $ref        = shift;
  my $lookingFor = shift;
  my $isSpouse   = shift;

  my $person = $ged->get_individual($ref);

  #----------------------------------------------------------------------------
  # don't process people more than once otherwise we will never terminate
  #----------------------------------------------------------------------------

  if ( alreadySeenDown( $ref, $person ) ) {
    return;
  }
  $searchesPerformed++;

  #----------------------------------------------------------------------------
  # don't process if we have already found who we're looking fo
  #----------------------------------------------------------------------------

  return if $found;

  #----------------------------------------------------------------------------
  # record progress
  #----------------------------------------------------------------------------
  push @downTrace, $person->xref;

  debugPrint( "Searching down from", $person->cased_name, $person->xref )
    if $DEBUGGING;

  if ( $person->xref eq $lookingFor ) {

    # set the found flag and store the down trace and the spouse status
    $found          = 1;
    @foundDownTrace = @downTrace;
    $spouseFlag     = $isSpouse;
    debugPrint( "Found", $person->cased_name ) if $DEBUGGING;
    return;
  }

  #----------------------------------------------------------------------------
  # is this not a leaf node? i.e. the person has children or a spouse, if so
  # process the children and spouse, otherwise just pop the node off the down
  # trace
  #----------------------------------------------------------------------------
  if ( $person->children || $person->spouse ) {
    if ( $person->children ) {
      foreach my $child ( $person->children ) {
        searchDown( $child->xref, $lookingFor, 0 );
      }
    }

    # TODO multiple spouses cause problems becuse we pop the root too early
    my $dummy = pop @downTrace;
    debugPrint( "Root Node $dummy popped", join( ',', @downTrace ) )
      if $DEBUGGING;
    if ( $person->spouse ) {
      foreach my $spouse ( $person->spouse ) {
        debugPrint( "Spouse", $spouse->cased_name ) if $DEBUGGING;
        searchDown( $spouse->xref, $lookingFor, 1 );
      }
    }

    #--------------------------------------------------------------------------
    # we've now searched the tree rooted at this person and not found who we are
    # looking for in any of their children (and etc.) so we pop them off the
    # trace
    #--------------------------------------------------------------------------
  } else {
    my $dummy = pop @downTrace;
    debugPrint( "Leaf Node $dummy popped", join( ',', @downTrace ) )
      if $DEBUGGING;
  }
}

sub nextLevelUp {

  #----------------------------------------------------------------------------
  # from a person, add their father and mother - from a father and mother add
  # their fathers and mothers, etc.
  #----------------------------------------------------------------------------

  foreach my $indi ( keys %currentList ) {
    my $depth = $currentList{$indi}{depth};
    my $name  = $currentList{$indi}{name};

    my $person = $ged->get_individual($indi);
    if ( $person->father ) {
      my $father = $person->father;
      if ( !exists $currentList{$father} ) {
        $currentList{ $father->xref }{name}  = $father->cased_name;
        $currentList{ $father->xref }{depth} = $depth + 1;
      }
    }
    if ( $person->mother ) {
      my $mother = $person->mother;
      if ( !exists $currentList{$mother} ) {
        $currentList{ $mother->xref }{name}  = $mother->cased_name;
        $currentList{ $mother->xref }{depth} = $depth + 1;
      }
    }
  }
  debugPrint( "Current List is", Dumper(%currentList) ) if $DEBUGGING;
  return;
}

sub initLevel {
  my $ref    = shift;
  my $person = $ged->get_individual($ref);
  %currentList                         = ();
  $currentList{ $person->xref }{name}  = $person->cased_name;
  $currentList{ $person->xref }{depth} = 0;
}

sub printLevel {
  my $minDepth = shift;
  my $adjust   = -1 * $minDepth;
  $adjust = 0 if $adjust < 0;
  foreach my $indi ( keys %currentList ) {
    my $depth = $currentList{$indi}{depth};
    my $name  = $currentList{$indi}{name};
    say ' ' x ( $depth + $adjust ), $name . " ($indi)";
  }
  say ' ';
}

sub addFound {

  # first find the maximum depth before we add, note that minimum depth is
  # always 0 at this point
  my $maxDepth = 0;
  my $minDepth;
  my $depth;
  $weird = 0;

  debugPrint( "Found Down Trace is", join( ',', @foundDownTrace ) )
    if $DEBUGGING;

  foreach my $indi ( keys %currentList ) {
    $maxDepth = $currentList{$indi}{depth};
  }

  foreach my $indi (@foundDownTrace) {
    if ( !defined $depth ) {

      # the first person we process should always be in %currentList already and
      # so we pick up the depth from here

      if ( exists $currentList{$indi} ) {
        $depth = $currentList{$indi}{depth};
      } else {

        # for multiple spouses this happens so try to use the depth of the last
        # person in the list
        foreach my $hope ( keys %currentList ) {
          $depth = $currentList{$hope}{depth};
        }
        $depth++;
        $weird = 1;
        debugPrint( 'Warning', $indi, 'not in current list, depth set to',
          $depth );
      }
    }

    my $person = $ged->get_individual($indi);

    if ( !exists $currentList{$indi} ) {
      $currentList{$indi}{name}  = $person->cased_name;
      $currentList{$indi}{depth} = --$depth;
      debugPrint("Adding $indi to current list") if $DEBUGGING;
    }
  }
  $minDepth = $depth;
  return ( $minDepth, $maxDepth );
}

sub alreadySeenUp {
  my $ref    = shift;
  my $person = shift;
  if ( $seenHashUp{$ref} ) {
    debug( $ref, "up skipped because already seen" ) if $DEBUGGING;
    return 1;
  } else {

    $seenHashUp{$ref} = $person->cased_name;
    return 0;
  }
}

sub alreadySeenDown {
  my $ref    = shift;
  my $person = shift;
  if ( $seenHashDown{$ref} ) {
    debugPrint( $ref, "down skipped because already seen" ) if $DEBUGGING;
    return 1;
  } else {
    debugPrint( $ref, "added to down" ) if $DEBUGGING;
    $seenHashDown{$ref} = $person->cased_name;
    return 0;
  }
}

sub sexID {
  my $testID  = shift;
  my @phrases = @_;
  my $person  = $ged->get_individual($testID);
  if ( $person->sex eq "M" ) {
    return $phrases[0];
  } else {
    return $phrases[1];
  }
}

sub debugPrint {
  my @data = @_;
  say join( ' ', @data );
}
