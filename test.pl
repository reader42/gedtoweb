use Modern::Perl;
use Gedcom;

my $ged = Gedcom->new( gedcom_file => 'Family.ged' );

my $target = $ged->get_individual('I8');

searchTargetsParents( $target, '29 SEP 1939' );

# scan a person to locate a correctly dated residence record that has the target
# person as a witness, if found return the person and the other witnesses
sub findTargetAsWitness {

  my $person = shift;
  my $target = shift;
  my $date   = shift;

  my @resis = $person->record('residence');
  foreach my $resi (@resis) {
    if ( $resi->get_value('date') eq $date ) {

      # say "Found residence for $date";
      my @witnesses = ();
      my $found     = 0;
      if ( $resi->sharedref ) {
        my @shared = $resi->record('sharedref');
        foreach my $witness (@shared) {
          $witness = $witness->get_value;
          if ( $witness eq $target ) {

            # say "Target found in ", $resi->get_value('date');
            $found = 1;
          } else {
            push @witnesses, $witness;
          }
        }
      }
      if ($found) {
        unshift @witnesses, $person->xref;

        # say "Witnesses: ", join(', ',@witnesses);
        return @witnesses;
      }
    }
  }
  return;
}

# serach the parents to find a witnessed residence that contains the target to
# match the census date

sub searchTargetsParents {
  my $target    = shift;
  my $date      = shift;
  my @witnesses = ();
  my $father    = $target->father();
  my $mother    = $target->mother();
  if ($father) {
    @witnesses = findTargetAsWitness( $father, $target->xref, $date );
    if (@witnesses) {
      #say "Found with father in $date: ", join( ', ', @witnesses );
      return @witnesses;
    }
  }
  if ($mother) {
    @witnesses = findTargetAsWitness( $mother, $target->xref, $date );
  }
  if (@witnesses) {
    # say "Found with mother in $date: ", join( ', ', @witnesses );
    return @witnesses;
  }
  # say "Not found with either parent";
  return;
}
