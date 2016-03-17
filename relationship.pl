#===============================================================================
#
#         FILE: relationship.pl
#
#        USAGE: relationship.pl
#
#  DESCRIPTION: Read a GEDCOM file and calculate realtionships
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Pete Barlow (PB), langbard@gmail.com
# ORGANIZATION:
#      VERSION: 1.0
#      CREATED: 13/03/2016
#     REVISION:
#===============================================================================

use Modern::Perl;
use Gedcom;
use Log::Log4perl qw(get_logger :levels);
use Tie::IxHash;
use Data::Dumper;
use Lingua::EN::Inflect qw(ORD);

#------------------------------------------------------------------
# Standard locations for this User (perl 5)
#------------------------------------------------------------------
my $userprofile = $ENV{USERPROFILE};
my $dropbox     = $userprofile . '/Dropbox/';
my $googledrive = $userprofile . '/Google Drive/';
my $onedrive    = $userprofile . '/OneDrive/';
my $desktop     = $userprofile . '/Desktop/';
my $documents   = $userprofile . '/Documents/';

my $ged = Gedcom->new( gedcom_file => 'Family.ged' );

#------------------------------------------------------------------
# test values
#------------------------------------------------------------------

my %tests = (
  I8    => 'Father',
  I10   => 'Sister',
  I16   => 'Niece',
  I1086 => 'Great Nephew',
  I12   => 'Grand Mother',
  I59   => 'Aunt',
  I22   => '1st Cousin',
  I1314 => '1st Cousin 1 times removed',
  I55   => 'Great Grand Father',
  I1192 => '1st Cousin 1 times removed',
  I1846 => '2nd Cousin',
  I122  => 'Great Great Grand Father',
  I220  => 'Great Great Uncle',
  I1145 => '1st Cousin 2 times removed',
  I838  => '2nd Cousin 2 times removed',
  I1582 => '2nd Cousin 1 times removed',
  I1738 => '3rd Cousin',
  I277  => 'Great Great Great Grand Father',
  I832  => '1st Cousin 3 times removed',
  I1651 => '3rd Cousin 1 times removed',
  I1449 => '4th Cousin',
  I176  => 'Great Great Great Aunt',
  I204  => 'Great Aunt',
  I1183 => '1st Cousin 2 times removed',
  I216  => 'Husband of Great Great Aunt',
  I45   => 'Husband of Aunt',
  I13   => 'Uncle',
  I6    => 'Daughter',
  I1717 => 'Husband of Sister',
  I116  => 'Wife of Great Great Uncle',
  I37   => 'Unknown',
  I1120 => 'Great Great Grand Mother',
  I1212 => 'Great Grand Mother',
  I88 => 'Great Grand Mother',
);

# Global variables

my @foundDownTrace = ();
my $found          = 0;
my @downTrace      = ();
tie my %currentList, "Tie::IxHash";
my %seenHashUp;
my %seenHashDown;
my $weird = 0;

# shows that the person found is a spouse of an ancestor
my $spouseFlag;

# cumulative count of searches performed
my $searchesPerformed = 0;
my $DEBUGGING         = 0;

# TODO make it terminate when person isn't found
# $DEBUGGING = 1;
# say calculateRelationship('I1212');
# say calculateRelationship('I88');
# say calculateRelationship('I1120');
# exit;

foreach my $testID ( keys %tests ) {
  my $trial = calculateRelationship($testID);

  if ( $tests{$testID} ne $trial ) {
    say "$testID expected " . $tests{$testID} . " but got $trial";
    say "Spouse flag is $spouseFlag";
    say "Found person is " . sexID( $testID, "Male", "Female" );
    say ' ';
  }
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
    debug("Adding next level") if $DEBUGGING;
    if ( $searchesPerformed > $lastSearches ) {
      $lastSearches = $searchesPerformed;
    } else {
      return "Unknown";
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

  debug( "Maxdepth", $maxDepth, 'Difference', $difference ) if $DEBUGGING;

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

  debug( "Searching down from", $person->cased_name, $person->xref )
    if $DEBUGGING;

  if ( $person->xref eq $lookingFor ) {

    # set the found flag and store the down trace and the spouse status
    $found          = 1;
    @foundDownTrace = @downTrace;
    $spouseFlag     = $isSpouse;
    debug( "Found", $person->cased_name ) if $DEBUGGING;
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
    debug( "Root Node $dummy popped", join(',', @downTrace) ) if $DEBUGGING;
    if ( $person->spouse ) {
      foreach my $spouse ( $person->spouse ) {
        debug("Spouse", $spouse->cased_name) if $DEBUGGING;
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
    debug( "Leaf Node $dummy popped", join(',', @downTrace) ) if $DEBUGGING;
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
  debug( "Current List is", Dumper(%currentList) ) if $DEBUGGING;
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

  debug("Found Down Trace is", join(',', @foundDownTrace)) if $DEBUGGING;

  foreach my $indi ( keys %currentList ) {
    $maxDepth = $currentList{$indi}{depth};
  }

  foreach my $indi (@foundDownTrace) {
    if ( !defined $depth ) {

      # the first person we process should always be in %currentList already and
      # so we pick up the depth from here

      if (exists $currentList{$indi}) {
        $depth = $currentList{$indi}{depth};
      } else {
        # for multiple spouses this happens so try to use the depth of the last
        # person in the list
        foreach my $hope (keys %currentList) {
          $depth = $currentList{$hope}{depth};
        }
        $depth++;
        $weird = 1;
        debug('Warning', $indi, 'not in current list, depth set to', $depth);
      }
    }

    my $person = $ged->get_individual($indi);

    if ( !exists $currentList{$indi} ) {
      $currentList{$indi}{name}  = $person->cased_name;
      $currentList{$indi}{depth} = --$depth;
      debug("Adding $indi to current list") if $DEBUGGING;
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

    # debug((caller(2))[3], $ref, $person->cased_name);
    $seenHashUp{$ref} = $person->cased_name;
    return 0;
  }
}

sub alreadySeenDown {
  my $ref    = shift;
  my $person = shift;
  if ( $seenHashDown{$ref} ) {
    debug( $ref, "down skipped because already seen" ) if $DEBUGGING;
    return 1;
  } else {
    debug( $ref, "added to down" ) if $DEBUGGING;
    # debug((caller(2))[3], $ref, $person->cased_name);
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

sub debug {
  my @data = @_;
  say join( ' ', @data );
}
