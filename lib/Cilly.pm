#
#
# Copyright (c) 2001 by
#  George C. Necula	necula@cs.berkeley.edu
#  Scott McPeak        smcpeak@cs.berkeley.edu
#  Wes Weimer          weimer@cs.berkeley.edu
#   
# All rights reserved.  Permission to use, copy, modify and distribute
# this software for research purposes only is hereby granted, 
# provided that the following conditions are met: 
# 1. Redistributions of source code must retain the above copyright notice, 
# this list of conditions and the following disclaimer. 
# 2. Redistributions in binary form must reproduce the above copyright notice, 
# this list of conditions and the following disclaimer in the documentation 
# and/or other materials provided with the distribution. 
# 3. The name of the authors may not be used to endorse or promote products 
# derived from  this software without specific prior written permission. 
#
# DISCLAIMER:
# THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR 
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. 
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS 
# OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON 
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF 
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#



# This module implements a compiler stub that parses the command line
# arguments of gcc and Microsoft Visual C (along with some arguments for the
# script itself) and gives hooks into preprocessing, compilation and linking.

package Cilly;
@ISA = ();

use strict;
use File::Basename;
use File::Copy;
use Data::Dumper;

$Cilly::savedSourceExt = "_saved.c";

# Pass to new a list of command arguments
sub new {
    my ($proto, @args) = @_;


    my $class = ref($proto) || $proto;

    my $ref =
    { CFILES => [],    # C input files
      SFILES => [],    # Assembly language files
      OFILES => [],    # Other input files
      IFILES => [],    # Already preprocessed files
      PPARGS => [],    # Preprocessor args
      CCARGS => [],    # Compiler args
      LINKARGS => [],  # Linker args
      NATIVECAML => 1, # this causes the native code boxer to be used
      RELEASELIB => 0, # if true, use the release runtime library (if any)
      IDASHI => 1,     # if true, pass "-I-" to gcc's preprocessor
      IDASHDOT => 1,   # if true, pass "-I." to gcc's preprocessor
      VERBOSE => 0,    # when true, print extra detail
      OPERATION => 'TOEXE', # This is the default for all compilers
    };
    my $self = bless $ref, $class;

    if(! @args) {
        print "No arguments passed\n";
        $self->printHelp();
        exit 0;
    }
    # Look for the --mode argument first. If not found it is GCC
    my $mode;
    {
        my @args1 = ();
        foreach my $arg (@args) {
            if($arg =~ m|--mode=(.+)$|) {
                $mode = $1;
            } else {
                push @args1, $arg;
            }
        }
        @args = @args1; # These are the argument after we extracted the --mode
    }
    if(! defined($mode)) {
        $mode = 'GNUCC'; # Default is GCC
    }
    if(defined $self->{MODENAME} && $self->{MODENAME} ne $mode) {
        die "Cannot re-specify the compiler";
    }
    {
        my $compiler;
        if($mode eq "MSVC") {
            unshift @Cilly::ISA, qw(MSVC);
            $compiler = MSVC->new($self);
        } elsif($mode eq "GNUCC") {
            unshift @Cilly::ISA, qw(GNUCC);
            $compiler = GNUCC->new($self);
        } elsif($mode eq "MSLINK") {
            unshift @Cilly::ISA, qw(MSLINK);
            $compiler = MSLINK->new($self);
        } elsif($mode eq "AR") {
            unshift @Cilly::ISA, qw(AR);
            $compiler = AR->new($self);
        } else {
            die "Don't know about compiler $mode\n";
        }
        # Now grab the fields from the compiler and put them inside self
        my $key;
        foreach $key (keys %{$compiler}) {
            $self->{$key} = $compiler->{$key};
        }
    }
    # Scan and process the arguments
    while($#args >= 0) {
        my $arg = $self->fetchEscapedArg(\@args);
        if(! defined($arg)) {
            last;
        }
#
#        my $arg = shift @args; # Grab the next one
        if(! $self->collectOneArgument($arg, \@args)) {
            print "Warning: Unknown argument $arg\n";
            push @{$self->{CCARGS}}, $arg;
        }
    }
#    print Dumper($self);
    return $self;
}

# Grab the next argument and escape it if necessary
sub fetchEscapedArg {
    my ($self, $pargs) = @_;
    my $arg = shift @{$pargs};
        # Drop the empty arguments
    if($arg =~ m|^\s*$|) { 
        if($#{$pargs} > 0) {
            return $self->fetchEscapedArg($pargs); 
        } else {
            return undef;
        }
    }
        # See if it contains spaces
    $arg =~ s|(\s)|\\$1|g;
    $arg =~ s|(\")|\\\"|g;
    return $arg;
}

# Collecting arguments. Take a look at one argument. If we understand it then
# we return 1. Otherwise we return 0. Might pop soem more arguments from pargs.
sub collectOneArgument {
    my($self, $arg, $pargs) = @_;
    my $res;
    # Maybe it is a compiler option or a source file
    if($self->compilerArgument($self->{OPTIONS}, $arg, $pargs)) { return 1; }

    if($arg eq "--help" || $arg eq "-help") {
        $self->printHelp(); exit 1;
    }
    if($arg eq "--verbose") {
        $self->{VERBOSE} = 1; return 1;
    }
    if($arg eq "--flatten_linker_scripts") {
        $self->{FLATTEN_LINKER_SCRIPTS} = 1; return 1;
    }
    if($arg =~ m|--keep=(.+)$|) {
        $self->{KEEPDIR} = $1;
        if(! -d $self->{KEEPDIR}) {
            die "Cannot find directory $self->{KEEPDIR}";
        }
        return 1;
    }
    if($arg =~ m|--separate|) {
        $self->{SEPARATE} = 1;
        return 1;
    }
    if($arg eq '--keepmerged') {
        $self->{KEEPMERGED} = 1;
        return 1;
    }
    if($arg =~ m|--leavealone=(.+)$|)  {
        push @{$self->{LEAVEALONE}}, $1; return 1;
    }
    if($arg =~ m|--includedir=(.+)$|)  {
        push @{$self->{INCLUDEDIR}}, $1; return 1;
    }
    if($arg =~ m|--stages|) {
        $self->{SHOWSTAGES} = 1; 
        push @{$self->{CILARGS}}, $arg;
        return 1;
    }
    if($arg eq "--bytecode") {
        $self->{NATIVECAML} = 0; return 1;
    }
    if($arg eq "--no-idashi") {
        $self->{IDASHI} = 0; return 1;
    }
    if($arg eq "--no-idashdot") {
        $self->{IDASHDOT} = 0; return 1;
    }
    # All other arguments starting with -- are passed to CIL
    if($arg =~ m|^--|) {
        # Split the ==
        if($arg =~ m|^(--\S+)=(.+)$|) {
            push @{$self->{CILARGS}}, $1, $2; return 1;
        } else {
            push @{$self->{CILARGS}}, $arg; return 1;
        }
    }
    return 0;
}



sub printHelp {
    my($self) = @_;
    $self->usage();
    print <<EOF;
Options:
  --mode=xxx   What tool to emulate:
                GNUCC   - GNU gcc
                MSVC    - MS VC cl compiler
                MSLINK  - MS VC link linker
                AR      - GNU ar
               This option must be the first one! If it is not found there
               then GNUCC mode is assumed.
  --help (or -help) Prints this help message
  --verbose    Prints a lot of information about what is being done
  --keep=xxx   Keep temporary files in the given directory
  --separate   Apply CIL separately to each source file as they are compiled. 
               By default CIL is applied to the whole program during linking.
  --keepmerged  Save the merged file. Only useful if --separate is not given.
  --trueobj          Do not write preprocessed sources in .obj files but
                     create some other files.
 
  --leavealone=xxx   Leave alone files whose base name is xxx. This means
                     they are not merged and not processed with CIL.
  --includedir=xxx   Adds a new include directory to replace existing ones
  --stages           Show the processing stages
  --bytecode         Invoke the bytecode (as opposed to native code) system

EOF
    $self->helpMessage();
}

# For printing the first line of the help message
sub usage {
    my ($self) = @_;
    print "<No usage is defined>";
}

# The rest of the help message
sub helpMessage {
    my ($self) = @_;
    print <<EOF;
Send bugs to necula\@cs.berkeley.edu.
EOF
}

#
# The basic routines: for ech source file preprocess, compile, then link
# everything 
#
#


# LINKING into a library (with COMPILATION and PREPROCESSING)
sub straight_linktolib {
    my ($self, $psrcs, $dest, $ppargs, $ccargs, $ldargs) = @_;
    my @sources = ref($psrcs) ? @{$psrcs} : ($psrcs);
    $dest = $dest eq "" ? "" : $self->{OUTLIB} . $dest;
    # Pass the linkargs last because some libraries must be passed after
    # the sources
    my $cmd = $self->{LDLIB} . " $dest " . 
        join(' ', @{$ppargs}, @{$ccargs}, @sources, @{$ldargs});
    return $self->runShell($cmd);
}

# Customize the linking into libraries
sub linktolib {
    my($self, $psrcs, $dest, $ppargs, $ccargs, $ldargs) = @_;
    if($self->{VERBOSE}) { print "Linking into library $dest\n"; }
    if($self->{SEPARATE}) {
        # Not merging. Regular linking.
        return $self->straight_linktolib($psrcs, $dest, 
                                         $ppargs, $ccargs, $ldargs);
    }
    # We are merging

    # Now collect the files to be merged
    my @sources = ref($psrcs) ? @{$psrcs} : ($psrcs);

    # Write the names of the files into a file with the extension files
    open(FILES, ">$dest.files") || die("Cannot open $dest.files");
    print FILES join("\n", @sources);
    if($self->{VERBOSE}) {
        print "Saved to $dest.files the list of names composing $dest\n";
    }
    close(FILES);

    # Now link as usual, without calling CIL
    return $self->straight_linktolib($psrcs, $dest, 
                                     $ppargs, $ccargs, $ldargs);
}

############
############ PREPROCESSING
############
#
# All flavors of preprocessing return the destination file
#

# THIS IS THE ENTRY POINT FOR COMPILING SOURCE FILES
sub preprocess_compile {
    my ($self, $src, $dest, $ppargs, $ccargs) = @_;
    my ($base, $dir, $ext) = fileparse($src, "\\.[^.]+");
    if($ext eq ".c" || $ext eq ".cpp") {
        if($self->leaveAlone($src)) {
            # We leave this alone. So just compile as usual
            return $self->straight_compile($src, $dest, $ppargs, $ccargs);
        }
        my $out    = $self->preprocessOutputFile($src);
        $out = $self->preprocess($src, $out, $ppargs);
        $src = $out;
        $ext = ".i";
        # fall-through to compilation
    }
    if($ext eq ".i") {
        $self->compile($src, $dest, $ppargs, $ccargs);
    }
}

# THIS IS THE ENTRY POINT FOR JUST PREPROCESSING A FILE
sub preprocess {
    my($self, $src, $dest, $ppargs) = @_;
    return $self->preprocess_before_cil($src, $dest, $ppargs);
}

# Find the name of the preprocessed file
sub preprocessOutputFile {
    my($self, $src) = @_;
    my ($base, $dir, $ext) = fileparse($src, "\\.[^.]+");
    my $idir = $dir;
    if(defined $self->{KEEPDIR}) { $idir = $self->{KEEPDIR} . "/"; }
    return "$idir$base.i";
}

# When we use CIL we have two separate preprocessing stages. First is the
# preprocessing before the CIL sees the code and the is the preprocessing
# after CIL sees the code
 
sub preprocess_before_cil {
    my ($self, $src, $dest, $ppargs) = @_;
    my @args = @{$ppargs};

    # See if we must force some includes
    if(defined $self->{INCLUDEDIR}) {
        # And force the other includes. Put them at the begining
        if(($self->{MODENAME} eq 'GNUCC') &&
           # sm: m88k doesn't work if I pass -I.
           $self->{IDASHDOT}) {
            unshift @args, "-I.";
        }
        unshift @args,
            map { my $dir = $_;
                  $self->{INCARG} . $dir . "/" . $self->{VERSION} }
            @{$self->{INCLUDEDIR}};
        if($self->{MODENAME} eq 'GNUCC') {
            # sm: this is incompatible with wu-ftpd, but is apparently needed
            # for apache.. more investigation is needed
            # update: now when I try it, apache works without -I- also.. but
            # I'll make this into a switchable flag anyway
            if ($self->{IDASHI}) {
                unshift @args, "-I-";
            }
        }
    }

    return $self->straight_preprocess($src, $dest, \@args);
}

# Preprocessing after CIL
sub preprocess_after_cil {
    my ($self, $src, $dest, $ppargs) = @_;
    return $self->straight_preprocess($src, $dest, $ppargs);
}

#
# This is intended to be the true invocation of the underlying preprocessor
# You should not override this method
sub straight_preprocess {
    my ($self, $src, $dest, $ppargs) = @_;
    if($self->{VERBOSE}) { print "Preprocessing $src\n"; }
    if($self->{MODENAME} eq "MSVC") {
        $self->MSVC::msvc_preprocess($src, $dest, $ppargs);
    } else {
        my $cmd = $self->{CPP} . " " . 
            join(' ', @{$ppargs}) . " $src " . $self->{OUTCPP} . $dest;
        $self->runShell($cmd);
        
    }
    return $dest;
}


#
#
#
# COMPILATION
#
#

sub compile {
    my($self, $src, $dest, $ppargs, $ccargs) = @_;
    if($self->{SEPARATE}) {
        # Now invoke CIL and compile after wards
        return $self->applyCilAndCompile([$src], $dest, $ppargs, $ccargs); 
    }
    # We are merging
    # If we are merging then we just save the preprocessed source
    my ($mtime, $res, $outfile);
    if(! $self->{TRUEOBJ}) {
        $outfile = $dest; $mtime = 0; $res   = $dest;
    } else {
        # Do the real compilation
        $res = $self->straight_compile($src, $dest, $ppargs, $ccargs);
        # Now stat the result 
        my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
            $atime,$mtime_1,$ctime,$blksize,$blocks) = stat($dest);
        if(! defined($mtime_1)) {
            die "Cannot stat the result of compilation $dest";
        }
        $mtime = $mtime_1;
        $outfile = $dest . $Cilly::savedSourceExt;
    }
    # sm: made the following output unconditional following the principle
    # that by default you should be able to see every file getting written
    # during a build (otherwise you don't know who to ask to be --verbose)
    if(1 || $self->{VERBOSE}) { print "Saving source $src into $outfile\n"; }
    open(OUT, ">$outfile") || die "Cannot create $outfile";
    my $toprintsrc = $src; $toprintsrc =~ s|\\|/|g;
    print OUT "#pragma merger($mtime, \"$toprintsrc\", \"" . 
        join(' ', @{$ccargs}), "\")\n";
    open(IN, "<$src") || die "Cannot read $src";
    print OUT <IN>; 
    close(OUT);
    close(IN);
    return $res;
} 

# This is the actual invocation of the underlying compiler. You should not
# override this 
sub straight_compile {
    my ($self, $src, $dest, $ppargs, $ccargs) = @_;
    if($self->{VERBOSE}) { print "Compiling $src into $dest\n"; }
    $dest = $dest eq "" ? "" : $self->{OUTOBJ} . $dest;
    my $forcec = $self->{FORCECSOURCE};
    my $cmd = $self->{CC} . " " . join(' ', @{$ppargs}, @{$ccargs}) .  
        " $dest $forcec$src";
    return $self->runShell($cmd);
}

# This is compilation after CIL
sub compile_cil {
    my ($self, $src, $dest, $ppargs, $ccargs) = @_;
    return $self->straight_compile($src, $dest, $ppargs, $ccargs);
}



# THIS IS THE ENTRY POINT FOR JUST ASSEMBLING FILES
sub assemble {
    my ($self, $src, $dest, $ppargs, $ccargs) = @_;
    if($self->{VERBOSE}) { print "Assembling $src\n"; }
    $dest = $dest eq "" ? "" : $self->{OUTOBJ} . $dest;
    my $cmd = $self->{CC} . " " . join(' ', @{$ppargs}, @{$ccargs}) .  
        " $dest $src";
    return $self->runShell($cmd);
}



#
# This is intended to be the true invocation of the underlying linker
# You should not override this method
sub straight_link {
    my ($self, $psrcs, $dest, $ppargs, $ccargs, $ldargs) = @_;
    my @sources = ref($psrcs) ? @{$psrcs} : ($psrcs);
    $dest = $dest eq "" ? "" : $self->{OUTEXE} . $dest;
    # Pass the linkargs last because some libraries must be passed after
    # the sources
    my $cmd = $self->{LD} . " " . 
        join(' ', @{$ppargs}, @{$ccargs}, @sources, @{$ldargs}) .  
            " $dest";
    return $self->runShell($cmd);
}


# Customize the linking
sub link {
    my($self, $psrcs, $dest, $ppargs, $ccargs, $ldargs) = @_;
    if($self->{VERBOSE}) { print "Linking into $dest\n"; }
    if($self->{SEPARATE}) {
        # Not merging. Regular linking.
        return $self->link_after_cil($psrcs, $dest, $ppargs, $ccargs, $ldargs);
    }
    # We must merging
    
    # Now collect the files to be merged
    my $src;
    my @sources = ref($psrcs) ? @{$psrcs} : ($psrcs);
    # Go through the sources and replace all libraries with the files that
    # they contain
    my @sources1 = ();
    while($#sources >= 0) {
        my $src = shift @sources;
#        print "Looking at $src\n";
        # See if the source is a library. Then maybe we should get instead the 
        # list of files
        if($src =~ m|\.$self->{LIBEXT}$|) {
            if(-f "$src.files") {
                open(FILES, "<$src.files") || die "Cannot read $src.files";
                while(<FILES>) {
                    # Put them back in the sources to process them recursively
                    if($_ =~ m|\n$|) {
                        chop;
                    }
                    unshift @sources, $_;
                }
                close(FILES);
                next;
            }
        }
        push @sources1, $src;
        next;
    }
    @sources = @sources1;
#    print "Sources are @sources\n";
    my @tomerge = ();
    my @othersources = ();
    foreach $src (@sources) {
        my ($combsrc, $mtime);
        if(! $self->{TRUEOBJ}) {
            $combsrc = $src;
            $mtime = 0;
            } else {
                $combsrc = $src . $Cilly::savedSourceExt;
                if(-f $combsrc) { 
                    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
                        $atime,$mtime_1,$ctime,$blksize,$blocks) = stat($src);
                    $mtime = $mtime_1;
                } else {
                    $mtime = 0;
                }
            }
        # Look inside and see if it is one of the files created by us
        open(IN, "<$combsrc") || die "Cannot read $combsrc";
        my $fstline = <IN>;
        if($fstline =~ m|\#pragma merger\((\d+)|) {
            if($1 == $mtime) { # It is ours
                push @tomerge, $combsrc; 
                next;
            }
        }
        push @othersources, $src;
    }

    my $mergedobj = $dest . "_comb.o";
    $self->applyCilAndCompile(\@tomerge, $mergedobj, $ppargs, $ccargs); 
    push @othersources, $mergedobj;

    # And finally link
    # sm: hack: made this conditional for dsw
    if (!defined($ENV{CILLY_DONT_LINK_AFTER_MERGE})) {
      $self->link_after_cil(\@othersources, $dest, $ppargs, $ccargs, $ldargs);
    }

}

sub applyCilAndCompile {
    my ($self, $ppsrc, $dest, $ppargs, $ccargs) = @_;
    
    # The input files
    my @srcs = @{$ppsrc};

    # Prepare the name of the CIL output file based on dest
    my ($base, $dir, $ext) = fileparse($dest, "(\\.[^.]+)");
    
    # Now prepare the command line for invoking cilly
    my ($cmd, $aftercil) = $self->CillyCommand ($dir, $base);
    $cmd .= " ";

    if($self->{MODENAME} eq "MSVC") {
        $cmd .= " --MSVC ";
    }
    if($self->{VERBOSE}) {
        $cmd .= " --verbose ";
    }
    if(defined $self->{CILARGS}) {
        $cmd .=  join(' ', @{$self->{CILARGS}}) . " ";
    }

    # Add the arguments
    if(@srcs > 20) {
        my $extraFile = "___extra_files";
        open(TOMERGE, ">$extraFile") || die $!;
        foreach my $fl (@srcs) {
            print TOMERGE "$fl\n";
        }
        close(TOMERGE);
        $cmd .= " --extrafiles $extraFile ";
    } else {
        $cmd .= join(' ', @srcs) . " ";
    }
    if($self->{KEEPMERGED}) {
        $cmd .= " --mergedout $dir$base" . ".c ";
    }
    # Now run cilly
    $self->runShell($cmd);

    # Now preprocess
    my $aftercilpp = $self->preprocessOutputFile($aftercil);
    $self->preprocess_after_cil($aftercil, $aftercilpp, $ppargs);

    # Now compile
    return $self->compile_cil($aftercilpp, $dest, $ppargs, $ccargs);
}

# Linking after CIL
sub link_after_cil {
    my ($self, $psrcs, $dest, $ppargs, $ccargs, $ldargs) = @_;
    return $self->straight_link($psrcs, $dest, $ppargs, $ccargs, $ldargs);
}

# See if we must merge this one
sub leaveAlone {
    my($self, $filename) = @_;
    my ($base, $dir, $ext) = fileparse($filename, "(\\.[^.]+)");
    if(grep { $_ eq $base } @{$self->{LEAVEALONE}}) {
        return 1;
    } else {
        return 0;
    }
}


# DO EVERYTHING
sub doit {
    my ($self) = @_;
    my $file;
    my $out;

    # Maybe we must preprocess only
    if($self->{OPERATION} eq "TOI") {
        # Then we do not do anything
        my $cmd = $self->{CPP} . " " . 
            join(' ', @{$self->{PPARGS}}, @{$self->{CCARGS}}, 
                      @{$self->{CFILES}}, @{$self->{SFILES}},
                      $self->{OUTARG});
        return $self->runShell($cmd);
    }
    # If only one source then apply CIL directly
    if($self->{OPERATION} eq "TOEXE" &&
       @{$self->{CFILES}} + @{$self->{IFILES}} == 1) {
#        $self->{SEPARATE} = 1; 
    }

    # Turn everything into OBJ files
    my @tolink = (@{$self->{OFILES}});

    foreach $file (@{$self->{IFILES}}, @{$self->{CFILES}}) {
        $out = $self->compileOutputFile($file);
        $self->preprocess_compile($file, $out, 
                                  $self->{PPARGS}, $self->{CCARGS});
        push @tolink, $out;
    }
    # Now do the assembly language file
    foreach $file (@{$self->{SFILES}}) {
        $out = $self->assembleOutputFile($file);
        $self->assemble($file, $out, $self->{PPARGS}, $self->{CCARGS});
        push @tolink, $out;
    }

    # See if we must stop after compilation
    if($self->{OPERATION} eq "TOOBJ") {
        return;
    }

    # See if we must create a library only
    if($self->{OPERATION} eq "TOLIB") {
        $out = $self->linkOutputFile();
        $self->linktolib(\@tolink,  $out, 
                         $self->{PPARGS}, $self->{CCARGS}, 
                         $self->{LINKARGS});
        return;
    }

    # Now link all of the files into an executable
    if($self->{OPERATION} eq "TOEXE") {
        $out = $self->linkOutputFile();
        $self->link(\@tolink,  $out, 
                    $self->{PPARGS}, $self->{CCARGS}, $self->{LINKARGS});
        return;
    }
    die "I don't understand OPERATION:$self->{OPERATION}\n";
}

sub classDebug {
    if(0) { print @_; }
}

sub compilerArgument {
    my($self, $options, $arg, $pargs) = @_;
    &classDebug("Classifying arg: $arg\n");
    my $idx = 0;
    for($idx=0; $idx < $#$options; $idx += 2) {
        my $key = ${$options}[$idx];
        my $action = ${$options}[$idx + 1];
        &classDebug("Try match with $key\n");
        if($arg =~ m|^$key|) {
          &classDebug(" match with $key\n");
          my $fullarg = $arg;
          my $onemore;
          if(defined $action->{'ONEMORE'}) {
              &classDebug("  expecting one more\n");
              # Maybe the next arg is attached
              my $realarg;
              ($realarg, $onemore) = ($arg =~ m|^($key)(.+)$|);
              if(! defined $onemore) {
                  # Grab the next argument
                  $onemore = $self->fetchEscapedArg($pargs);
                  $onemore = &quoteIfNecessary($onemore);
                  $fullarg .= " $onemore";
              } else {
                  $onemore = &quoteIfNecessary($onemore);
              }
              &classDebug(" onemore=$onemore\n");
          }
          # Now see what action we must perform
          my $argument_done = 1;
          if(defined $action->{'RUN'}) {
              &{$action->{'RUN'}}($self, $fullarg, $onemore, $pargs);
              $argument_done = 1;
          }
          if(defined $action->{'TYPE'}) {
              &classDebug("  type=$action->{TYPE}\n");
              if($action->{TYPE} eq "PREPROC") {
                  push @{$self->{PPARGS}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "CC") {
                  push @{$self->{CCARGS}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "LINKCC") {
                  push @{$self->{CCARGS}}, $fullarg; 
                  push @{$self->{LINKARGS}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "LINK") {
                  push @{$self->{LINKARGS}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "CSOURCE") {
                  push @{$self->{CFILES}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "ASMSOURCE") {
                  push @{$self->{SFILES}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "OSOURCE") {
                  push @{$self->{OFILES}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq "ISOURCE") {
                  push @{$self->{IFILES}}, $fullarg; return 1;
              }
              if($action->{TYPE} eq 'OUT') {
                  if(defined($self->{OUTARG})) {
                      print "Warning: output file is multiply defined: $self->{OUTARG} and $fullarg\n";
                  }
                  $self->{OUTARG} = $fullarg; return 1;
              }
              print "  Do not understand TYPE\n"; return 1;
          }
          if($argument_done) { return 1; }
          print "Don't know what to do with option $arg\n"; 
          return 0;
      }
   }
   return 0;
}


sub runShell {
    my ($self, $cmd) = @_;

    # sm: I want this printed to stderr instead of stdout
    # because the rest of 'make' output goes there and this
    # way I can capture to a coherent file
    # sm: removed conditional on verbose since there's already
    # so much noise in the output, and this is the *one* piece
    # of information I *always* end up digging around for..
    if(1 || $self->{VERBOSE}) { print STDERR "$cmd\n"; }

    # weimer: let's have a sanity check
    my $code = system($cmd);
    if ($code != 0) {
        # sm: now that we always print, don't echo the command again,
        # since that makes the output more confusing
	#die "Possible error with $cmd!\n";
	$code >>= 8;    # extract exit code portion

        exit $code;
    } 
    return $code;
}

sub quoteIfNecessary {
    my($arg) = @_;
    # If it contains spaces or "" then it must be quoted
    if($arg =~ m|\s| || $arg =~ m|\"|) {
        return "\'$arg\'";
    } else {
        return $arg;
    }
}



###########################################################################
####
#### MS CL specific code
####
package MSVC;

use strict;
use File::Basename;

sub new {
    my ($proto, $stub) = @_;
    my $class = ref($proto) || $proto;
    # Create $self

    my $self = 
    { NAME => 'Microsoft cl compiler',
      MODENAME => 'MSVC',
      CC => 'cl /nologo /D_MSVC /c',
      CPP => 'cl /nologo /D_MSVC /P',
      LD => 'cl /nologo /D_MSVC',
      DEFARG  => "/D",
      INCARG  => "/I",
      DEBUGARG => "/Zi /MLd /DEBUG",
      OPTIMARG => "/Ox /G6 ",
      OBJEXT => "obj",
      LIBEXT => "lib",   # Library extension (without the .)
      EXEEXT => ".exe",  # Executable extension (with the .)
      OUTOBJ => "/Fo",
      OUTEXE => "/Fe",
      FORCECSOURCE => "/Tc",
      LINEPATTERN => "^#line\\s+(\\d+)\\s+\"(.+)\"",

      OPTIONS => 
# Describe the compiler options as a list of patterns and associated actions. 
# The patterns are matched in order against the _begining_ of the argument.
#
# If the action contains ONEMORE => 1 then the argument is expected to be
# parameterized by a following word. The word can be attached immediately to
# the end of the argument or in a separate word. 
#
# If the action contains TYPE => "..." then the argument is put into one of
# several lists, as follows: "PREPROC" in ppargs, "CC" in ccargs, "LINK" in
# linkargs, "LINKCC" both in ccargs and linkargs, "CSOURCE" in cfiles, 
# "ASMSOURCE" in sfiles, 
# "OSOURCE" in ofiles, "ISOURCE" in ifiles, "OUT" in outarg. 
#
# If the TYPE is not defined but the RUN => sub { ... } is defined then the
# given subroutine is invoked with the self, the argument and the (possibly
# empty) additional word and a pointer to the list of remaining arguments
#
          ["[^/].*\\.(c|cpp|cc)\$" => { TYPE => 'CSOURCE' },
           "[^/].*\\.(asm)\$" => { TYPE => 'ASMSOURCE' },
           "[^/].*\\.i\$" => { TYPE => 'ISOURCE' },
           "[^/-]" => { TYPE => "OSOURCE" },
           "/O" => { TYPE => "CC" },
           "/G" => { TYPE => "CC" },
           "/[DI]" => { TYPE => "PREPROC"},
           "/EH" => { TYPE => "CC" },
           "/G"  => { TYPE => "CC" },
           "/F[aA]"  => { TYPE => 'CC' },
           "/Fo"     => { TYPE => 'OUT' },
           "/Fe"   => { TYPE => 'OUT',
                        RUN => sub { $stub->{OPERATION} = "TOEXE" }},
           "/F[dprR]" => { TYPE => "CC" },
           "/[CXu]" => { TYPE => "PREPROC" },
           "/U" => { ONEMORE => 1, TYPE => "PREPROC" },
           "/(E|EP|P)" => { RUN => sub { push @{$stub->{PPARGS}}, $_[1]; 
                                         $stub->{OPERATION} = "PREPROC"; }},
           "/c" => { RUN => sub { $stub->{OPERATION} = "TOOBJ"; }},
           "/(Q|Z|J|nologo|TC|TP|w|W|Yd|Zm)" => { TYPE => "CC" },
           "/v(d|m)" => { TYPE => "CC" },
           "/F" => { TYPE => "CC" },
           "/M"   => { TYPE => 'LINKCC' },
           "/link" => { RUN => sub { push @{$stub->{LINKARGS}}, "/link", 
                                          @{$_[3]};
                                     @{$_[3]} = (); } },
           "/"  => { RUN => 
                         sub { print "Unimplemented MSVC argument $_[1]\n";}},
           ],
      };
    bless $self, $class;
    return $self;
}


sub msvc_preprocess {
    my($self, $src, $dest, $ppargs) = @_;
    my $res;
    my ($sbase, $sdir, $sext) = 
        fileparse($src, 
                  "(\\.c)|(\\.cc)|(\\.cpp)|(\\.i)");
    my $cmd = "cl /nologo /P /D_MSVC " . join(' ', @{$ppargs});
    $res = $self->runShell("$cmd $src");
    # MSVC cannot be told where to put the output. But we know that it
    # puts it in the current directory
    my $msvcout = "./$sbase.i";
    my @st1 = stat $msvcout;
    my @st2 = stat $dest;
    while($#st1 >= 0) {
        if(shift @st1 != shift @st2) {
#                print "$msvcout is NOT the same as $afterpp\n";
            if($self->{VERBOSE}) {
                print "Copying $msvcout to $dest\n";
            }
            unlink $dest;
            &File::Copy::copy($msvcout, $dest);
            unlink $msvcout;
            return $res;
        }
    }
    return $res;
}

sub forceIncludeArg { 
    my($self, $what) = @_;
    return "/FI$what";
}


    # MSVC does not understand the extension .i, so we tell it it is a C file
sub fixupCsources {
    my (@csources) = @_;
    my @mod_csources = ();
    my $src;
    foreach $src (@csources) {
        my ($sbase, $sdir, $sext) = fileparse($src, 
                                              "\\.[^.]+");
        if($sext eq ".i") {
            push @mod_csources, "/Tc";
        }
        push @mod_csources, $src;
    }
    return @mod_csources;
}


# Emit a line # directive
sub lineDirective {
    my ($self, $fileName, $lineno) = @_;
    return "#line $lineno \"$fileName\"\n";
}

# The name of the output file
sub compileOutputFile {
    my($self, $src) = @_;
    if($self->{OUTARG} =~ m|/Fo(.+)|) {
        return $1;
    }
    my ($base, $dir, $ext) = 
        fileparse($src, 
                  "(\\.c)|(\\.cc)|(\\.cpp)|(\\.i)|(\\.asm)");
    if(! defined($ext) || $ext eq "") { # Not a C source
        die "objectOutputFile: not a C source file\n";
    }
    return "$base.obj"; # In the current directory
}

sub assembleOutputFile {
    my($self, $src) = @_;
    return $self->compileOutputFile($src);
}

sub linkOutputFile {
    my($self, $src) = @_;
    if($self->{OUTARG} =~ m|/Fe(.+)|) {
        return $1;
    }
    return "a.exe";
}

sub setVersion {
    my($self) = @_;
    my $cversion = "";
    open(VER, "cl 2>&1|") || die "Cannot start Microsoft CL\n";
    while(<VER>) {
        if($_ =~ m|Compiler Version (\S+) |) {
            $cversion = "cl_$1";
            close(VER);
            $self->{VERSION} = $cversion;
            return;
        }
    }
    die "Cannot find Microsoft CL version\n";
}

########################################################################
##
##  MS LINK specific code
##
###
package MSLINK;

use strict;

use File::Basename;

sub new {
    my ($proto, $stub) = @_;
    my $class = ref($proto) || $proto;
    # Create $self

    my $self = 
    { NAME => 'Microsoft linker',
      MODENAME => 'mslink',
      CC => 'no_compiler_in_mslink_mode',
      CPP => 'no_compiler_in_mslink_mode',
      LD => 'cl /nologo',
      DEFARG  => " ??DEFARG",
      INCARG  => " ??INCARG",
      DEBUGARG => "/DEBUG",
      OPTIMARG => "",
      OBJEXT => "obj",
      LIBEXT => "lib",   # Library extension (without the .)
      EXEEXT => ".exe",  # Executable extension (with the .)
      OUTOBJ => " ??OUTOBJ",
      OUTEXE => "/OUT:",
      LINEPATTERN => "", 

      OPTIONS => 
          ["[^/-]" => { TYPE => 'OSOURCE' },
           "/OUT:" => { TYPE => 'OUT' },
           "/"  => { TYPE => 'LINK' },
           ],
      };
    bless $self, $class;
    return $self;
}


sub forceIncludeArg {  # Same as for CL
    my($self, $what) = @_;
    return "/FI$what";
}



sub linkOutputFile {
    my($self, $src) = @_;
    if($self->{OUTARG} =~ m|/OUT:(.+)|) {
        return $1;
    }
    die "I do not know what is the link output file\n";
}

########################################################################
##
##  GNU ar specific code
##
###
package AR;

use strict;

use File::Basename;

sub new {
    my ($proto, $stub) = @_;
    my $class = ref($proto) || $proto;
    # Create $self

    my $self = 
    { NAME => 'Archiver',
      MODENAME => 'ar',
      CC => 'no_compiler_in_ar_mode',
      CPP => 'no_compiler_in_ar_mode',
      LDLIB => 'ar crv',
      DEFARG  => " ??DEFARG",
      INCARG  => " ??INCARG",
      DEBUGARG => "??DEBUGARG",
      OPTIMARG => "",
      OBJEXT => "o",
      LIBEXT => "a",   # Library extension (without the .)
      EXEEXT => "",  # Executable extension (with the .)
      OUTOBJ => " ??OUTOBJ",
      OUTLIB => "",  # But better be first
      LINEPATTERN => "", 

      OPTIONS => 
          ["." => { RUN => \&arArguments } ]

      };
    bless $self, $class;
    return $self;
}

# We handle arguments in a special way for AR
sub arArguments {
    my ($self, $arg, $onemore, $pargs) = @_;
    # If the first argument starts with -- pass it on
    if($arg =~ m|^--|) {
        return 0;
    }
    # We got here for the first non -- argument. 
    # Will handle all arguments at once
#    print "AR called with $arg ", join(' ', @{$pargs}), "\n";
    if($arg !~ m|c| || $arg !~ m|r| || $#{$pargs} < 0) {
        die "AR implements only the cr operation";
    }
    # Get the name of the library
    $self->{OUTARG} = shift @{$pargs};
    unlink $self->{OUTARG};
    # The rest must be object files
    push @{$self->{OFILES}}, @{$pargs};
    $self->{OPERATION} = 'TOLIB';
    @{$pargs} = ();
    return 1;
}

sub linkOutputFile {
    my($self, $src) = @_;
    if(defined $self->{OUTARG}) {
        return $self->{OUTARG};
    }
    die "I do not know what is the link output file\n";
}



#########################################################################
##
## GNUCC specific code
##
package GNUCC;

use strict;

use File::Basename;

# The variable $::cc is inherited from the main script!!

sub new {
    my ($proto, $stub) = @_;
    my $class = ref($proto) || $proto;
    # Create $self

    my $self = 
    { NAME => 'GNU CC',
      MODENAME => 'GNUCC',  # do not change this since it is used in code
      # sm: added -O since it's needed for inlines to be merged instead of causing link errors
      # sm: removed -O to ease debugging; will address "inline extern" elsewhere
      CC => "$::cc -D_GNUCC -c",
      LD => "$::cc -D_GNUCC ",
      CPP => "$::cc -D_GNUCC -E ",
      DEFARG  => "-D",
      INCARG => "-I",
      DEBUGARG => "-g",
      OPTIMARG => "-O4",
      CPROFILEARG => "-pg ",
      LPROFILEARG => "-pg ",
      OBJEXT => "o",
      LIBEXT => "a",
      EXEEXT => "",
      OUTOBJ => "-o ",
      OUTEXE => "-o ",
      OUTCPP => "-o ",
      LINEPATTERN => "^#\\s+(\\d+)\\s+\"(.+)\"",
      
      OPTIONS => 
          [ "[^-].*\\.(c|cpp|cc)\$" => { TYPE => 'CSOURCE' },
            "[^-].*\\.(s|S)\$" => { TYPE => 'ASMSOURCE' },
            "[^-].*\\.i\$" => { TYPE => 'ISOURCE' },
            # .o files can be linker scripts
            "[^-]" => { RUN => sub { &GNUCC::parseLinkerScript(@_); }},
            "-E"   => { RUN => sub { $stub->{OPERATION} = "TOI"; }},
            "-[DI]" => { ONEMORE => 1, TYPE => "PREPROC" },
            "-include" => { ONEMORE => 1, TYPE => "PREPROC" },  # sm
            "-ansi" => { TYPE => "PREPROC" },
            "-c" => { RUN => sub { $stub->{OPERATION} = "TOOBJ"; }},
            "-x" => { ONEMORE => 1, TYPE => "CC" },
             # GCC defines some more macros if the optimization is On so pass
             # the -O2 to the preprocessor and the compiler
            "-O" => { TYPE => "PREPROC" },
            "-S" => { RUN => sub { $stub->{OPERATION} = "TOOBJ";
                                   push @{$stub->{CCARGS}}, $_[1]; }},
            "-o" => { ONEMORE => 1, TYPE => 'OUT' },
            "-p" => { TYPE => 'LINKCC' },
            "-W" => { TYPE => 'CC' },
            "-g" => { RUN => sub { push @{$stub->{CCARGS}}, $_[1];
                                   push @{$stub->{LINKARGS}}, $_[1]; }},
            "-l" => { TYPE => 'LINK' },
            "-L" => { TYPE => 'LINK' },
            "-f" => { TYPE => 'LINKCC' },
            "-r" => { TYPE => 'LINK' },
            "-m" => { TYPE => 'LINKCC' },
            "-Xlinker" => { ONEMORE => 1, TYPE => 'LINK' },
            "-nostdlib" => { TYPE => 'LINK' },
            "-traditional" => { TYPE => 'PREPROC' },
            "-std" => { TYPE => 'CC' },
            ],
                                  
      };
    bless $self, $class;
    return $self;
}

my $linker_script_debug = 0;
sub parseLinkerScript {
    my($self, $filename, $onemore, $pargs) = @_;
    
    if(! defined($self->{FLATTEN_LINKER_SCRIPTS}) ||
       $filename !~ /\.o$/) {
      NotAScript:
        warn "$filename is not a linker script\n" if $linker_script_debug;
        push @{$self->{OFILES}}, $filename; 
        return 1;
    }
    warn "parsing OBJECT FILE:$filename ****************\n" if
        $linker_script_debug;
    open OBJFILE, $filename or die $!;
    my $line = <OBJFILE>;
    if ($line !~ /^INPUT/) {
        close OBJFILE or die $!;
        goto NotAScript;
    }
    warn "\tYES an INPUT file.\n" if $linker_script_debug;
    my @lines = <OBJFILE>; # Read it all and close it
    unshift @lines, $line;
    close OBJFILE or die $!;
    # Process recursively each line from the file
    my @tokens = ();
    my $incomment = 0; # Whether we are in a comment
    foreach my $line (@lines) {
        chomp $line;
        if($incomment) {
            # See where the comment ends
            my $endcomment = index($line, "*/");
            if($endcomment < 0) { # No end on this line
                next; # next line
            } else {
                $line = substr($line, $endcomment + 2); 
                $incomment = 0;
            }
        }
        # Drop the comments that are on a single line
        $line =~ s|/\*.*\*/| |g;
        # Here if outside comment. See if a comment starts
        my $startcomment = index($line, "/*");
        if($startcomment >= 0) {
            $incomment = 1;
            $line = substr($line, 0, $startcomment);
        }
        # Split the line into tokens. Sicne we use parentheses in the pattern
        # the separators will be tokens as well
        push @tokens, split(/([(),\s])/, $line);
    }
    print "Found tokens:", join(':', @tokens), "\n" 
        if $linker_script_debug;
    # Now parse the file
    my $state = 0;
    foreach my $token (@tokens) {
        if($token eq "" || $token =~ /\s+/) { next; } # Skip spaces
        if($state == 0) {
            if($token eq "INPUT") { $state = 1; next; } 
            else { die "Error in script: expecting INPUT"; }
        }
        if($state == 1) { 
            if($token eq "(") { $state = 2; next; } 
            else { die "Error in script: expecting ( after INPUT"; }
        } 
        if($state == 2) { 
            if($token eq ")") { $state = 0; next; }
            if($token eq ",") { next; } # Comma could be a separator
            # Now we better see a filename
            if(! -f $token) {
               warn "Linker script mentions inexistent file:$token.Ignoring\n";
               next;
            }
            # Process it recursively because it could be a script itself
            warn "LISTED FILE:$token.\n" if $linker_script_debug;
            $self->parseLinkerScript($token, $onemore, $pargs);
            next;
        } 
        die "Invalid linker script parser state\n";
        
    }
}

sub forceIncludeArg { 
    my($self, $what) = @_;
    return "-include $what";
}


# Emit a line # directive
sub lineDirective {
    my ($self, $fileName, $lineno) = @_;
    return "# $lineno \"$fileName\"\n";
}

# The name of the output file
sub compileOutputFile {
    my($self, $src) = @_;
    if($self->{OUTARG} =~ m|^-o\s*(\S.+)$| && $self->{OPERATION} eq 'TOOBJ') {
        return $1;
    }
    my ($base, $dir, $ext) = 
        fileparse($src, 
                  "(\\.c)|(\\.cc)|(\\.cpp)|(\\.i)|(\\.[s|S])");
    if(! defined($ext) || $ext eq "") { # Not a C source
        die "objectOutputFile: not a C source file: $src\n";
    }
    return "$base.o"; # In the current directory
}

sub assembleOutputFile {
    my($self, $src) = @_;
    return $self->compileOutputFile($src);
}

sub linkOutputFile {
    my($self, $src) = @_;
    if($self->{OUTARG} =~ m|-o\s*(\S.+)|) {
        return $1;
    }
    return "a.out";
}

sub setVersion {
    my($self) = @_;
    my $cversion = "";
    open(VER, "$::cc -dumpversion " 
         . join(' ', @{$self->{PPARGS}}) ." |") 
        || die "Cannot start GNUCC";
    while(<VER>) {
        if($_ =~ m|^(\d+\S+)| || $_ =~ m|^(egcs-\d+\S+)|) {
            $cversion = "gcc_$1";
            close(VER) || die "Cannot start GNUCC\n";
            $self->{VERSION} = $cversion;
            return;
        }
    }
    die "Cannot find GNUCC version\n";
}

1;


__END__


