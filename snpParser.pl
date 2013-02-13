#! /usr/bin/perl/ -w
use strict;
use Statistics::R; #interact with R
require 'fileParser.pl';
require 'bedHandler.pl';

use MyConstants qw( $CHRNUM $supportedList $supportedTags );

# the sub routines to process snps
# input
#	$snpFile	the snp file name (path)
#	$powCount	the threshold for powerful (frequent) snps
# output
#	\@snpList	the hash reference containing both
#			powerful and non-powerful snps as well as
#			their indices (_idx).
sub initSnp{
  #snps and powSnps
  my @snps = (); my @powSnps = ();
  for(my $i=0; $i<=$CHRNUM; $i++){
    push @snps, {};
    push @powSnps, {};
  }
  
  
  my ($snpFile, $powCount) = @_;
  open(my $fh, "<", $snpFile) or die "Cannot open snp file: $snpFile for reading.\n";
  print "Reading from $snpFile\n";

  # Create a communication bridge with R and start R
  my $R = Statistics::R->new();
  
  my $count = 0;
  while(<$fh>){
    $count++;
    if(!$count%1000){
      #print $count." ";
    }
    chomp;
    my ($chrRaw, $pos, $alleles, $snpName, $reads)=split(/ /, $_);
    my ($refAl, $altAl, $wrngAl) = split(/:/, $reads);

    my $chrID = getChrID($chrRaw); #auxiliary from fileparser.pl
    #check numeric
    if(!($chrID=~/^\d+$/)){
      #print "$chrID\n"; 
      next; 
    }
    #do the R Chi-squared Test
    my $totalAl = $refAl+$altAl;
    my $infoKept = $pos."\t".$alleles."\t".$snpName."\t".$refAl."\t".$altAl.";";
    #print "Ref: $refAl, Alt: $altAl, Total: $totalAl\n";
    if($totalAl>=$powCount){ #powerful snp
      
      #use the R object to make a Chi-squared goodness-of-fit test
      $R->set('x', [$refAl, $altAl]);
      $R->run('p = chisq.test(x)$p.value'); #default expected dist is c(0.5, 0.5)
      my $pValue = $R->get('p');

      #print "Chr $chrID: Ref: $refAl, Alt: $altAl, Total: $totalAl\n";
      #print "Chi-squared test\t$pValue\n";
      
      #bionomial test (exact):
      #$R->run("p2 = binom.test($refAl, $totalAl, 0.5)");
      #my $testBin = $R->get('p2');
      #print "Binomial test\t\t";
      #my $resBin = join(' ', @$testBin);
      #if($resBin=~/p-value\s*[<|=]\s*(\S+)/){
      #  print "$1\n";
      #}

      if(defined($powSnps[$chrID]{$pos})){
	  print "Warning: multiple powerful SNVs at the same position: $pos with ".$powSnps[$chrID]{$pos}."\n";
      }	  
      $powSnps[$chrID]{$pos} .= $pValue."\t".$infoKept;	
    }elsif($totalAl>=2){ #non-trivial snps? following Gang's version
      if(defined($snps[$chrID]{$pos})){
        print "Warning: multiple SNVs at the same position: $pos with ".$snps[$chrID]{$pos}."\n";
      }
      $snps[$chrID]{$pos} .= "1\t".$infoKept;  #add 1 as the fake p-value for ordinary snps
    }

  }
  close($fh);
  $R->stop;

  #create array indices
  my @snp_idx = (); my @powSnps_idx = ();
  for(my $i=1; $i<=$CHRNUM; $i++){
     $snp_idx[$i] = [sort {$a<=>$b} keys %{$snps[$i]}];
     $powSnps_idx[$i] = [sort {$a<=>$b} keys %{$powSnps[$i]}];
  }

  my %snpList = (
    'snps' => \@snps,
    'powSnps' => \@powSnps,
    'snps_idx' => \@snp_idx,
    'powSnps_idx' => \@powSnps_idx,
  );

  return \%snpList;
}


# Reimplementation of snp2asdensity.snp2exon
# To get all snp information located by genes (see snpVSTrans for details)
# "Locating the positions of the SNV in the transcriptome"
# input
#	$snpRef		reference to the SNP list
#	$transRef	reference to the trasncript list
# output
#	reference to the integrated gene snp list with snp info and gene locations
sub setGeneSnps{
  my ($snpRef, $transRef) = @_;

  my ($powSnps, $powSnps_idx) = snpVsTrans($snpRef, $transRef, 'powSnps'); #powerful snps
  my ($ordSnps, $ordSnps_idx) = snpVsTrans($snpRef, $transRef, 'snps'); #non-trivial snps

  my %geneSnps = (
   'gSnps' => $ordSnps,
   'gSnps_idx' => $ordSnps_idx,
   'gPowSnps' => $powSnps,
   'gPowSnps_idx' => $powSnps_idx,
  );

  return \%geneSnps;
}


# The corresponding core part to snp2asdensity.snp2exon
# A wrapper call setGeneSnps will call this twice using $snpTypeKey 'snps' and 'powSnps'
# to get all snp information located by genes
# "Locating the positions of the SNV in the transcriptome"
# input
#	$snpRef		reference to the SNP list
#	$transRef	reference to the trasncript list
#	$snpTypeKey	SNP type to be tested from the SNP list ('snps' or 'powSnps')
# output
#	references to the gene snp info and gene locations

sub snpVsTrans{
  my ($snpRef, $transRef, $snpTypeKey) = @_;

  my @geneSnps = ();
  my @geneLocations = ();
  for(my $i=0; $i<=$CHRNUM; $i++){
    push @geneSnps, {};
    push @geneLocations, {};
  }

  for(my $i=1; $i<=$CHRNUM; $i++){ #for each chromosome
    my %genes = %{$geneSnps[$i]};
    my %index = %{$geneLocations[$i]};
    my %geneMinTxStarts = (); #auxiliary to store minimal txStart for each gene


    my ($chrSnps, $chrSnps_idx) = getListByKeyChr($snpRef, $snpTypeKey, $i);
    my ($chrTrans, $chrTrans_idx) = getListByKeyChr($transRef, 'trans', $i);
    my %snps = %$chrSnps; my @snps_idx = @$chrSnps_idx; # for this chr only
    my %trans = %$chrTrans; my @trans_idx = @$chrTrans_idx; # this chr only

    if(@snps_idx==0 || @trans_idx==0){
      next;
    }
    #print "Processing "; printChr($i); print "\t";
    #print "SNVs ($snpTypeKey): ", scalar @snps_idx, "; ";
    #print "Transcripts: ", scalar @trans_idx, "\n";
    
    my ($si, $ti) = (0, 0);
    while($si<@snps_idx && $ti<@trans_idx){
      my $sPos = $snps_idx[$si];
      #print "$si VS $ti: $sPos VS $trans_idx[$ti]\n";
      if($sPos < $trans_idx[$ti]){
        #print "\$si++\n";
        $si+=1; next;
      }else{ #now the SNP is larger than some transcript start
        my $newTi = $ti; #store the old ti position
	# we have to check all $trans_idx[$newTi] until $sPos is not longer larger
        while($newTi<@trans_idx && $sPos >= $trans_idx[$newTi]){
	  my $tPos = $trans_idx[$newTi];
	  my @tSet = split('\t', $trans{$tPos});
	  my $maxTxEnd = -1; #to store the largest transcript end of @tSet
	  foreach(@tSet){
	    my ($txEnd, $cdsStart, $cdsEnd, $exonStarts, $exonEnds, $id, $gene, $isCoding, $txStrand) = split(';', $_);
	    if($txEnd > $maxTxEnd){	$maxTxEnd = $txEnd;	}#always store the max transcript end
	    if($sPos<=$txEnd){ # there is a hit
	       #$sPos<= $txEnd means the next $sPos may still match txEnd in @tSet, can't increase $ti.
	       # further checking
	       my @exss = split(',', $exonStarts);
	       my @exes = split(',', $exonEnds);
	       my $exNo = @exss; 
	       if($exNo != @exes){ die "exon no.s inconsistent: $exNo VS ".(scalar @exes);  }
	       
	       my $snpInfoToAdd = '';
	       for(my $j=0; $j<$exNo; $j++){
	         my $type = '';
	         if($sPos >= $exss[$j] && $sPos <= $exes[$j]){ #in exon
	           #5'UTR or 3'UTR check
	           if($j==0){
		     if($txStrand eq '+' && $sPos <$cdsStart){ #5'UTR
		       $type = '5\'UTR:+';
		     }elsif($txStrand eq '-' && $sPos <$cdsStart){ #3'UTR reverse strand
		       $type = '3\'UTR:-';
		     }else{
		       if($txStrand eq '+'){  $type = 'first:+'; }
		       else{ $type = 'last:+';  }
		     }
		   }elsif($j == $exNo-1){ #last exon start/first exon end: hv to know strand
		     if($txStrand eq '+' && $sPos >$cdsEnd){ #3'UTR
		       $type = '3\'UTR:+';
		     }
		     elsif($txStrand eq '-' && $sPos >$cdsEnd){ #5'UTR on reverse strand
		       $type = '5\'UTR:-';
		     }else{ 
		       if($txStrand eq '-'){  $type = 'first:-'; }
		       else{ $type = 'last:-';  }
		     }
		   }else{
		     $type = 'normal:'.$txStrand;
		   }
		   $snpInfoToAdd = 'exon:'.$type.';'.$gene.';'.$tPos.";".$id.';'.$exss[$j].';'.$exes[$j];
		   last;
	         }
	       
	         if($j >0 && $sPos > $exes[$j-1] && $sPos < $exss[$j]){ # in intron
	           $snpInfoToAdd = 'intron:'.$txStrand.';'.$gene.';'.$tPos.";".$id.';'.($exes[$j-1]+1).';'.($exss[$j]-1);
		   last;
	         }
               }
	       # add to the geneSnps list:
	       if(!defined($geneMinTxStarts{$gene}) || $tPos < $geneMinTxStarts{$gene}){
	         $geneMinTxStarts{$gene} = $tPos; #initial or minimal position
	       }
	       $genes{$gene} .= $sPos.";".$snpInfoToAdd."\t";
	       #print $sPos,";".$snpInfoToAdd."\n";
	       # now just store all genes at location $tPos, it will be amended by %geneMinTxStarts
	       my $geneStub = $gene."\t";
	       if(!defined($index{$tPos}) || !($index{$tPos}=~/$geneStub/)){
	         $index{$tPos} .= $gene."\t"; #gene at this exon start
	       }
             }
	  } #end of foreach(@tSet)
          if($sPos > $maxTxEnd && $newTi == $ti){ #no longer need to check this
	    $ti += 1;
	  }
	  $newTi++; #hv to check all transcript starts that are < $sPos
	} #end while
	$si += 1; #$si has gone through all $newTi (i.e. all transcript starts <= $sPos)
      }
    }
    #sort out the locations for indices
    #foreach(keys %geneMinTxStarts){
    #  print "$_: ", $geneMinTxStarts{$_}, "\n";
    #}

    foreach my $pos (keys %index){
      my $newGeneList = '';
      my @genesStartAt = split('\t', $index{$pos});
      
      foreach(@genesStartAt){
        if(defined($geneMinTxStarts{$_}) && $geneMinTxStarts{$_}==$pos){ #this indexed position is really the minimal txStart
	  $newGeneList .= $_."\t"; #re-construct the list
	}#else{ print "$_ not starting minimally at $pos but ".$geneMinTxStarts{$_}."\n"; }
      }
      if($newGeneList eq ''){ #actually all the previous genes stored here are not minimal txStart
        #delete this position in hash
	delete $index{$pos};
      }else{ #update it with the newGeneList
        $index{$pos} = $newGeneList;
      }
    } #now the index is done
 
    $geneSnps[$i] = \%genes; #gene-based arrangement
    $geneLocations[$i] = \%index; #each gene index is its first exon start position in the chromosome
  } #end of for each chromosome
  
  return (\@geneSnps, \@geneLocations);
}

################ auxiliary subroutines #######################
# get an array of genes sorted according their locations
# input: 
#	$listRef	the reference to the gene SNP list
#	$key		the key for snps: 'gSnps' or 'gPowSnps'
#	$chr		the chromosome number of interest
# output:
#	\@sortedGenes	an array containing gene names, sorted in their locations

sub getChrGeneSnpsSorted{
  my ($listRef, $key, $chr) = @_;
  my ($gListRef, $gLocRef) = getListByKeyChr($listRef, $key, $chr); 

  my %geneLocs = %{$gLocRef};
  my @sortedGenes = ();
  for(sort {$a<=>$b} keys %geneLocs){
    push @sortedGenes, $geneLocs{$_};
  }
  return \@sortedGenes;
}

# get the snp info in a list
# input: 
#	$snpInfo	the information stored for a particular individual SNP
# output:
#	@		the SNP information as an array
sub getSnpInfo{
  my ($snpInfo) = @_;
  
  #my $infoKept = $pos."\t".$alleles."\t".$snpName."\t".$refAl."\t".$altAl.";";
  #$powSnps[$chrID]{$pos} .= $pValue."\t".$infoKept;
  return split('\t', $snpInfo);
}

#################################################
sub processASEWithNev
{
  my ($snpRef, $geneSnpRef, $snpEventsNevRef, $snvPValueCutoff, $asarpPValueCutoff, $alleleRatioCutoff) = @_;
  my %ss = %$snpEventsNevRef;

  my ($powAltRef, $snpAltRef, $powSpRef, $snpSpRef) = ($ss{'nevPowSnpAlt'}, $ss{'nevSnpAlt'}, $ss{'nevPowSnpSp'}, $ss{'nevSnpSp'});
  
  my @allPowAlts = @$powAltRef;
  my @allSnpAlts = @$snpAltRef;
  my @allPowSps = @$powSpRef; 
  my @allSnpSps = @$snpSpRef;
  
  # init the results
  my @aseGenes = ();
  my @asarpGenes = ();
  my @asarpSnps = ();
  for(my $i=0; $i<=$CHRNUM; $i++){
    push @aseGenes, {};
    push @asarpGenes, {};
    push @asarpSnps, {};
  }

  # Create a communication bridge with R and start R
  my $R = Statistics::R->new();
  
  for(my $i=1; $i<=$CHRNUM; $i++){
     #init
     my %aseGeneHash = ();
     my %asarpGeneHash = ();
     my %asarpSnpHash = ();

     my ($powGeneSnpChrRef) = getListByKeyChr($geneSnpRef, 'gPowSnps', $i);
     my %powGenes = %$powGeneSnpChrRef;
     my ($geneSnpChrRef) = getListByKeyChr($geneSnpRef, 'gSnps', $i);
     my %snpGenes = %$geneSnpChrRef;
     
     my ($snpChrRef) = getListByKeyChr($snpRef, 'powSnps', $i);
     my %powSnps = %$snpChrRef;
     my ($ordSnpChrRef) = getListByKeyChr($snpRef, 'snps', $i);
     my %ordSnps = %$ordSnpChrRef;


     my %powAlts = (); my %snpAlts = ();
     my %powSps = (); my %snpSps = ();

     # get ready for ASARP (AS and 5'/3' UTR alternation)
     if(defined($allPowAlts[$i])){  %powAlts = %{$allPowAlts[$i]};  }
     if(defined($allSnpAlts[$i])){  %snpAlts = %{$allSnpAlts[$i]};  }

     if(defined($allPowSps[$i])){  %powSps = %{$allPowSps[$i]};  }
     if(defined($allSnpSps[$i])){  %snpSps = %{$allSnpSps[$i]};  }
   
     if(keys %powGenes >0){  printChr($i); print"\n";  }
     #gene level ASE

     # Stage 1: check gene level ASE's\n
     # Step 1.1: Genes with >= 2 Snps, and >= 1 powSnp
     for(keys %powGenes){ #genes with >= 1 powSnp
       my $gene = $_;
       #print "Gene $gene\n";
       my $snpGroupRef = groupGeneSnps($powGenes{$gene});
       my %snpGroup = %$snpGroupRef;
       #print "grouped snp:\t";
       #for(keys %snpGroup){ 
       #  print "SNP $_: $snpGroup{$_}\n";
       #   my %snpHs = %{$snpGroup{$_}};
       #   for(keys %snpHs){
       #     print "$_: $snpHs{$_}\t";
       #   }
       #  print "\n";
       #} print "\n";


       my %aseList = (); #to store all the ASE snps not to be processed again
       
       my $aseCount = 0; # count of ASE snps
       my $aseInfo = '';
       for(keys %snpGroup){
         my @allSnpInfo = split(';', $powSnps{$_}); #separate by ;, if there are multiple snps at the same position
	 foreach(@allSnpInfo){
	   my ($p, $pos, $alleles, $snpId) = getSnpInfo($_);
           if($p <= $snvPValueCutoff){
	      $aseList{$pos} = 1; 
	      $aseInfo .= "$snpId,$p,$alleles,$pos\t";
	      $aseCount += 1;
	   }
	 }
       }
       # Step 1.2: all powSnps are ASEs and there are >=2 ASEs
       if($aseCount == keys %snpGroup && $aseCount >= 2){
         #print "Gene: $gene is a gene with all $aseCount ASE's: $aseInfo\n";
	 $aseGeneHash{$gene} = $aseInfo;

       }
       else{  
	 
	 #print "Gene: $gene is not gene-level ASE ($aseCount out of ".scalar(keys %snpGroup).")\n";
         #stage 2: ASARP: including Alternative splicing and 5'/3' Alt init/term
         #Step 2.1 get target (all snps passing NEV filter, incl. non-powerful snps) and control (non-ASE powerful snps) SNPs
	 #besids %snpGroup, we also need %ordSnpGroup
	 my %ordSnpGroup = ();
	 if(defined($snpGenes{$gene})){
           my $ordSnpGroupRef = groupGeneSnps($snpGenes{$gene});
           %ordSnpGroup = %$ordSnpGroupRef;
	 }
	 my %allSnpGroup = (%snpGroup, %ordSnpGroup); #merge all the snp groups
	 
	 for my $trgtPos (keys %allSnpGroup){ #each key is a snp
	   my $targetFlag = 0; #set if it satisfies the target SNV condition
	   my ($altInit, $altTerm, $altSpInfo) = ('', '', '');
	   
	   # Step 2.1.1. check if this snp is with any events, i.e. in any alternatively spliced regions (5'/3' or AS)
	   
	   my $stubEnd = ",".$trgtPos.",";
	   if(defined($powAlts{$gene})){
	     if($powAlts{$gene} =~ /([5|3][+|-])$stubEnd/){
	       $targetFlag = 1;
	       my $endType = $1; #the matched parenthesis
	       if($endType eq '5+' || $endType eq '5-'){
	         $altInit = $endType;
	       }else{
	         $altTerm = $endType;
	       }
	     }
	   }
	   # the first $altInit ne '' is imposed to save unnecessary time as the snp
	   # is either in %powAlts or %snpAlts
	   if($altInit eq '' && $altTerm eq '' && defined($snpAlts{$gene})){
	     if($snpAlts{$gene} =~ /([5|3][+|-])$stubEnd/){
	       $targetFlag = 1;
	       my $endType = $1; #the matched parenthesis
	       if($endType eq '5+' || $endType eq '5-'){
	         $altInit = $endType;
	       }else{
	         $altTerm = $endType;
	       }
	     }
	   }


	   #for Splicing the format is different
	   my $stubSplicing = ";".$trgtPos.";";
	   
	   if(defined($powSps{$gene})){
	     #print "sp: $powSps{$gene}\n";
	     if($powSps{$gene} =~ /$stubSplicing/){
	       $targetFlag = 1;
	       #need to get more information from the gene
	       $altSpInfo = 'Yes'; #just a dummy
	       # have not got the exact AS type yet, e.g. SE, RI, ASS, UN
	       #print "$trgtPos matched powSps in $gene\n";
	       #print "$powSps{$gene}\n";
	     }
	   }
	   # the first $altSpInfo ne '' is imposed to save unnecessary time as the snp
	   # is either in %powSps or %snpSps
	   if($altSpInfo eq '' && defined($snpSps{$gene})){
	     #print "ord sp: $snpSps{$gene}\n";
	     if($snpSps{$gene} =~ /$stubSplicing/){
	       $targetFlag = 1;
	       $altSpInfo = 'Yes'; #just a dummy
	       #print "$trgtPos matched snpSps in $gene\n";
	       #print "$snpSps{$gene}\n";
             }
	   }
           
	   if($targetFlag){

	     #Step 2.1.2 try to locate the control reference SNV (only from non-ASE powerful SNVs)
             for my $ctrlPos (keys %snpGroup){ #have to be powerful
	       if($ctrlPos == $trgtPos || defined($aseList{$ctrlPos})){ 
	         next; #cannot be the same pos, cannot be ASE SNP
	       }
	       # Step 2.1.3 make sure that $trgtPos and $ctrlPos are not in the same exon
	       if(areNotInSameExon(\%allSnpGroup, $trgtPos, $snpGroupRef, $ctrlPos)){
	         # a valid target-control SNV pair, now check their allele difference
		 # in the current implementation, one position is assumed to have possibly multiple SNV types separated by ';', so we need to split the tuple first

                 my $targetSnpInfo = undef;
		 if(defined($powSnps{$trgtPos})){
		   $targetSnpInfo = $powSnps{$trgtPos};
		 }elsif(defined($ordSnps{$trgtPos})){
		   $targetSnpInfo = $ordSnps{$trgtPos};
		 }else{
		   die "ERROR: SNP at position $trgtPos not recorded for gene $gene at Chr $i\n";
		 }

                 my @allTargetSnps = split(';', $targetSnpInfo);
		 for(@allTargetSnps){
	           my ($tP, $tPos, $tAlleles, $tSnpId, $tAllel1, $tAllel2) = getSnpInfo($_);
                 
		   # control can only be a powerful SNV
		   my @allControlSnps = split(';', $powSnps{$ctrlPos});
		   for(@allControlSnps){
		     my ($cP, $cPos, $cAlleles, $cSnpId, $cAllel1, $cAllel2) = getSnpInfo($_);
	   	     # Step 2.2 Performing fisher's test on target: $trgtPos VS control: $ctrlPos -- $_

		     #Step 2.3 Use the R object to make a Fisher's exact test
		     #print "testing [$tAllel1, $tAllel2, $cAllel1, $cAllel2]\n";
		     $R->set('x', [$tAllel1, $tAllel2, $cAllel1, $cAllel2]);
		     $R->run('xm = matrix(data = x, nrow = 2)');
		     $R->run('p = fisher.test(xm)$p.value');
		     my $pValue = $R->get('p');
		     #print "fisher test result 1: $pValue\n";
		     
		     #print "testing [$tAllel2, $tAllel1, $cAllel1, $cAllel2]\n";
		     $R->set('x2', [$tAllel2, $tAllel1, $cAllel1, $cAllel2]);
		     $R->run('xm2 = matrix(data = x2, nrow = 2)');
		     $R->run('p2 = fisher.test(xm2)$p.value');
		     my $pValue2 = $R->get('p2');
		     #print "fisher test result 2: $pValue2\n";
		     
		     if($pValue2 < $pValue){ $pValue = $pValue2; } #get smaller p-value
		     if($pValue <= $asarpPValueCutoff) { #significant
		       #print "significant ratio differences found! $gene: $trgtPos (AI: $altInit AT: $altTerm AS: $altSpInfo) VS $ctrlPos: $powSnps{$ctrlPos}\n";	 
		       #Step 2.4 Check if the allelic ratio difference is larger than the threshold
		       my $tRatio = $tAllel1/($tAllel1+$tAllel2);
		       my $cRatio = $cAllel1/($cAllel1+$cAllel2);
		       if(abs($tRatio-$cRatio) >= $alleleRatioCutoff or abs($tRatio-(1-$cRatio)) >= $alleleRatioCutoff){
		         #print "absolute ratio difference found: $tRatio VS $cRatio\n ASARP found!\n";
			 my $type ='';
			 if($altInit ne ''){  $type .= "AI:$altInit,"; } #alternative 5' initiation
			 if($altTerm ne ''){  $type .= "AT:$altTerm,"; } #alternative 3' termination
			 if($altSpInfo){ $type .= "AS:,"; } #alternative splicing
			 $asarpGeneHash{$gene} .= "$type;$pValue;$trgtPos $tSnpId $tAlleles $tAllel1:$tAllel2;$ctrlPos $cSnpId $cAlleles $cAllel1 $cAllel2\t"; 
			 my $snpStub = $gene.",".$tSnpId.",".$tAlleles."\t";
			 if(!defined($asarpSnpHash{$trgtPos}) || !($asarpSnpHash{$trgtPos} =~ /$snpStub/)){
			   $asarpSnpHash{$trgtPos} .= $type.$snpStub;
			 }
			 #last; #just need one control that's enough
		       }
		     }
		   }
		 }
	       }
	     }
	   }
	 }
       }
     }
     $aseGenes[$i] = \%aseGeneHash;
     $asarpGenes[$i] = \%asarpGeneHash;
     $asarpSnps[$i] = \%asarpSnpHash;

  }
  $R->stop;

  #collect all results
  my %allAsarps = (
   'ASEgene' => \@aseGenes,
   'ASARPgene' => \@asarpGenes,
   'ASARPsnp' => \@asarpSnps,
  );

  return \%allAsarps;
}

sub outputRawASARP{
  my ($allAsarpsRef, $key, $outputFile) = (undef, undef, undef);
  ($allAsarpsRef, $key, $outputFile) = @_;
 
  my $file = undef;
  if(defined($outputFile)){
   print "Output results to $outputFile\n";
   open($file, ">", $outputFile) or die "ERROR: Cannot open $outputFile to write the results\n";
   select $file; #redirect all output to the result file
  }

  my $header = '';
  my $isAsarp = 1;
  if($key eq 'ASEgene'){
    $header = "ASE gene level (all powerful SNVs are ASEs)";
    $isAsarp = 0;
  }elsif($key eq 'ASARPgene'){
    $header = "ASARP gene level";
  }elsif($key eq 'ASARPsnp'){
    $header = "ASARP snp level";
  }else{
    die "ERROR: Unsupported key for ASE/ASARP\n";
  }

  print $header."\n";
  my @allAsarps = @{$allAsarpsRef->{$key}};
  for(my $i=1; $i<=$CHRNUM; $i++){

    if(defined($allAsarps[$i])){
      my %chrRes = %{$allAsarps[$i]};
      for(keys %chrRes){
         print "$_\n";
	 my @info = split('\t', $chrRes{$_});
	 foreach(@info){
	   print "$_\n";
	 }
	 print "\n";
      }
    }
  }

  if(defined($file)){
    close($file);
    select STDOUT; # back to normal
  }

}

sub formatOutputVerNAR{

  my ($allAsarpsRef, $outputFile) = (undef, undef, undef);
  ($allAsarpsRef, $outputFile) = @_;
 
  my $file = undef;
  if(defined($outputFile)){
   print "Output results to $outputFile\n";
  }
  # init the output string structure
  my ($summary, $geneLevel, $snvLevel) = ("", "GENES\n", "SNVs\n");

  my @allGeneAses = @{$allAsarpsRef->{'ASEgene'}};
  my $aseCount = 0;
  for(my $i=1; $i<=$CHRNUM; $i++){

    if(defined($allGeneAses[$i])){
      my %chrRes = %{$allGeneAses[$i]};
      $aseCount += keys %chrRes;
      for(keys %chrRes){ #gene
	 #my @info = split('\t', $chrRes{$_});
	 $geneLevel .= formatChr($i)."\t".$_."\tAllASE\n";
      }
    }
  }
  if($aseCount>=2){	$summary .= "There are $aseCount genes";
  }else{		$summary .= "There is $aseCount gene"; }
  $summary .= " whose powerful SNVs are ASEs\n";
 
  my ($geneSumRef, $snvSumRef) = formatGeneLevelVerNAR($allAsarpsRef->{'ASARPgene'});
  my %snvHash = %$snvSumRef;
  for(keys %snvHash){
    if($_ eq 'AS'){
      $snvLevel .= "Alternative Splicing\n";
    }elsif($_ eq 'AI'){
      $snvLevel .= "Alternative Initiation\n";
    }elsif($_ eq 'AT'){
      $snvLevel .= "Alternative Termination\n";
    }else{
      print "ERROR: unknown SNV event type: $_\n";
      exit;
    }
    $snvLevel .= $snvHash{$_}."\n";
  }

  my %geneHash = %$geneSumRef;
  my ($cntI, $cntS, $cntT, $cntComp) = (0, 0, 0, 0);
  my ($cntSIT, $cntSI, $cntST, $cntIT) = (0, 0, 0, 0); #for complex genes
  for my $gene (keys %geneHash){
    my ($chr, $withTypes) = split('\t', $geneHash{$gene});
    my @allEvents = split(';', $withTypes);
    my $text = '';
    if(@allEvents > 1){
      ++$cntComp;
      if($withTypes =~ 'AI;' && $withTypes =~ 'AS;' && $withTypes =~ 'AT;'){
        ++$cntSIT;
      }
      elsif($withTypes =~ 'AI;' && $withTypes =~ 'AS;'){
        ++$cntSI;
      }
      elsif($withTypes =~ 'AS;' && $withTypes =~ 'AT;'){
        ++$cntST;
      }
      elsif($withTypes =~ 'AI;' && $withTypes =~ 'AT;'){
        ++$cntIT;
      }

      $text = "Complex";
    }else{
      if($allEvents[0] eq 'AI'){
        ++$cntI;
	$text = "Initiation";
      }elsif($allEvents[0] eq 'AS'){
        ++$cntS;
	$text = "Splicing";
      }elsif($allEvents[0] eq 'AT'){
        ++$cntT;
	$text = "Termination";
      }
    }
    $geneLevel .= join("\t", $chr, $gene, $text)."\n";
  }

  $summary .= "There are $cntI 5' alternative initiation genes\n";
  $summary .= "There are $cntT 3' alternative termination genes\n";
  $summary .= "There are $cntS alternative splicing genes\n";
  
  $summary .= "There are $cntComp complex evented genes where\n".
  "  There are $cntSIT alternative splicing, initiation and termination evented genes\n".
  "  There are $cntSI alternative splicing and initiation evented genes\n".
  "  There are $cntST alternative splicing and termination evented genes\n".
  "  There are $cntIT alternative initiation and termination evented genes\n";
  my $cntTotalAsarp = $cntI + $cntT + $cntS + $cntComp;

  $summary .= "There are $cntTotalAsarp event related (non-all-ASE) genes\n\n";

  return $summary.$snvLevel.$geneLevel;
}


sub formatGeneLevelVerNAR{
  my ($inputRef) = @_; 
  my @genes = @$inputRef;
  my ($geneCnt, $typeCnt) = 0;
  my %asarps = (); #store all gene level ASEs/ASARPs
  my %geneTypes = (); #store how many different events the genes have

  for(my $i=1; $i<=$CHRNUM; $i++){

    if(defined($genes[$i])){
      my %chrRes = %{$genes[$i]};
      $geneCnt += keys %chrRes;
      for my $gene (keys %chrRes){ #each gene
        my %tabu = (); #just for this gene
	
	my @info = split('\t', $chrRes{$gene});
	foreach(@info){
	 my ($event, $pAsarp, $target, $control) = split(';', $_);
	 my @allEvents = split(',', $event);
	 for(@allEvents){
	   my ($alt, $detail) = split(':', $_);
           if(!defined($tabu{$target.$alt})){
	     $asarps{$alt} .= $gene."\t".formatChr($i)." ". $target."\n";
	     $tabu{$target.$alt} = $detail;
	   }
	   my $stub = $alt.";";
	   if(!defined($geneTypes{$gene})){
	     $geneTypes{$gene} = formatChr($i)."\t";
	   }
	   if(!($geneTypes{$gene} =~ $stub)){
	     $geneTypes{$gene} .= $stub; #add this new alt type
	   }
	 }
	}
      }

    }
  }
  return (\%geneTypes, \%asarps);
}


sub areNotInSameExon
{
  my ($targetRef, $target, $controlRef, $control, $chrTransRef) = @_;
  my $targetSnpRef = $targetRef->{$target};
  my $controlSnpRef = $targetRef->{$control};
  my %targetSnp = %$targetSnpRef;
  my %controlSnp = %$controlSnpRef;

  # Step 1: a quick check with just the intersect exons (pre-screening)
  if(defined($targetSnp{'intron+'}) || defined($targetSnp{'intron-'}) ||defined($targetSnp{'intron+'}) || defined($targetSnp{'intron-'})){
    #print "one of the 2 snps is in intron\n";
    return 1;
  }
  
  for my $tag ('exon+', 'exon-'){ # same intron is also considered "NotInSameExon", not need for 'intron+', 'intron-'){

    if(defined($targetSnp{$tag}) && defined($controlSnp{$tag})){
      my ($tS, $tE, $tTransTxs) = split(';', $targetSnp{$tag});
      my ($cS, $cE, $cTransTxs) = split(';', $controlSnp{$tag});
      if($tS<=$cE && $cS<=$tE){ #exon overlaps
	#print "$tag: overlap: $tS-$tE $cS-$cE \n$target: $tTransTxs overlaps $control: $cTransTxs\n";
	return 0;
      }
    }
  }
  return 1;
}



#################################################
sub filterSnpEventsWithNev
{
  my ($snpRef, $geneSnpRef, $snpEventsRef, $bedF, $spEventsListRef, $nevCutoffLower, $nevCutoffUpper) = @_;
  
  # Preparation of all the splicing and 5'/3' alt init/term events from $snpEventsRef
  my %ss = %$snpEventsRef;
  my ($powAltRef, $snpAltRef, $powSpRef, $snpSpRef) = ($ss{'powSnpAlt'}, $ss{'snpAlt'}, $ss{'powSnpSp'}, $ss{'snpSp'});
  
  my @allPowAlts = @$powAltRef;
  my @allSnpAlts = @$snpAltRef;
  my @allPowSps = @$powSpRef; 
  my @allSnpSps = @$snpSpRef;
 

  # init of the result components
  my @nevPowAlts = ();
  my @nevSnpAlts = ();
  my @nevPowSps = ();
  my @nevSnpSps = ();

  print "Filtering splicing events (alternative splicing, 5'/3' alternations) based on NEV's.\n";
  for(my $i=1; $i<=$CHRNUM; $i++){
     #init
     # get ready for ASARP (splicing and 5'/3' alt init/term events)
     my %powAlts = %{$allPowAlts[$i]};
     my %snpAlts = %{$allSnpAlts[$i]};

     my %powSps = %{$allPowSps[$i]};
     my %snpSps = %{$allSnpSps[$i]};
   
     my $powAltCnt = keys %powAlts; my $snpAltCnt = keys %snpAlts;
     my $powSpCnt = keys %powSps;   my $snpSpCnt = keys %snpSps;
     # read bed file of this chromosome when it is needed
     my $bedRef = undef;
     if($powAltCnt  > 0 || $snpAltCnt > 0 || $powSpCnt > 0 || $snpSpCnt > 0){ #it only makes sense when snps are there
        #readBed
        printChr($i); print "\n";
	$bedRef = readBedByChr($bedF, $i);
     }

     #print "# for 5'/3' alt init/term events\n";
     #update (shortlist) the alt events with NEV values calculated from bed information
     if($powAltCnt  > 0){	$nevPowAlts[$i] = calAltEventNev(\%powAlts, $bedRef, $i, $nevCutoffLower, $nevCutoffUpper);	}
     if($snpAltCnt  > 0){ 	$nevSnpAlts[$i] = calAltEventNev(\%snpAlts, $bedRef, $i, $nevCutoffLower, $nevCutoffUpper);	}

     #print "#for splicing events NEV calculation\n";
     if($powSpCnt  > 0){       $nevPowSps[$i] = calSplicingEventNev(\%powSps, $bedRef, $i, $spEventsListRef, $geneSnpRef, 'gPowSnps', $nevCutoffLower, $nevCutoffUpper);	} 
     if($snpSpCnt  > 0){       $nevSnpSps[$i] = calSplicingEventNev(\%snpSps, $bedRef, $i, $spEventsListRef, $geneSnpRef, 'gSnps', $nevCutoffLower, $nevCutoffUpper); 	}
  }

  my %snpEventsNev = (
    'nevPowSnpAlt' => \@nevPowAlts,
    'nevSnpAlt' => \@nevSnpAlts,
    'nevPowSnpSp' => \@nevPowSps,
    'nevSnpSp' => \@nevSnpSps,
  );
  return \%snpEventsNev;

}


# group the gene's snps
# the input $geneSnps is the value containing all snps under the gene key (a string not yet split)
sub groupGeneSnps
{
  my ($geneSnps) = @_;
  my %groups = ();
  
  #print "Group GeneSnps $geneSnps\n\n";
  # side-track: get all Snps first
  my %snps = ();
  my %snpsNeg = ();
  
  my %snpsIn = ();
  my %snpsNegIn = ();


  # now you can refine the exons that contain this snp (getting the minimal exon overlap)
  my %snpExonStarts = (); #get the intersect exon start for each snp
  my %snpExonEnds = (); #get the interset exon end for each snp
  my %snpIntronStarts = ();
  my %snpIntronEnds = ();

  my %snpNegExonStarts = ();
  my %snpNegExonEnds = ();
  my %snpNegIntronStarts = ();
  my %snpNegIntronEnds = ();
  my @allSnps = split('\t', $geneSnps);
  foreach(@allSnps){
    my ($snpPos, $exonIntronType, $geneName, $txStart, $transId, $exonS, $exonE) =  split(';', $_);
    my @typeInfo = split(':', $exonIntronType); 
    if($typeInfo[-1] eq '+'){ #forward strand
      if($typeInfo[0] eq 'exon'){
        $snps{$snpPos} .= $txStart.','; #defined now
        if(!defined($snpExonStarts{$snpPos}) || $snpExonStarts{$snpPos} < $exonS){
          $snpExonStarts{$snpPos} = $exonS;
        }
        if(!defined($snpExonEnds{$snpPos}) || $snpExonEnds{$snpPos} > $exonE){
          $snpExonEnds{$snpPos} = $exonE;
        }
      }
      else{ # intron type
        $snpsIn{$snpPos} .= $txStart.','; #defined now
        if(!defined($snpIntronStarts{$snpPos}) || $snpIntronStarts{$snpPos} < $exonS){
          $snpIntronStarts{$snpPos} = $exonS;
        }
        if(!defined($snpIntronEnds{$snpPos}) || $snpIntronEnds{$snpPos} > $exonE){
          $snpIntronEnds{$snpPos} = $exonE;
        }
      }
    }else{ #strand is -
      if($typeInfo[0] eq 'exon'){
	$snpsNeg{$snpPos} .= $txStart.','; #defined now
        if(!defined($snpNegExonStarts{$snpPos}) || $snpNegExonStarts{$snpPos} < $exonS){
          $snpNegExonStarts{$snpPos} = $exonS;
        }
        if(!defined($snpNegExonEnds{$snpPos}) || $snpNegExonEnds{$snpPos} > $exonE){
          $snpNegExonEnds{$snpPos} = $exonE;
        }
      }
      else{ # intron type
        $snpsNegIn{$snpPos} .= $txStart.','; #defined now
        if(!defined($snpNegIntronStarts{$snpPos}) || $snpNegIntronStarts{$snpPos} < $exonS){
          $snpNegIntronStarts{$snpPos} = $exonS;
        }
        if(!defined($snpNegIntronEnds{$snpPos}) || $snpNegIntronEnds{$snpPos} > $exonE){
          $snpNegIntronEnds{$snpPos} = $exonE;
        }
      }
    }
  }

  for(keys %snps){
    if(!defined($groups{$_})){
      $groups{$_} = {}; #empty hash
    }
    my %hash = %{$groups{$_}};
    if(defined($snpExonStarts{$_})){
      $hash{'exon+'} = join(';', $snpExonStarts{$_}, $snpExonEnds{$_}, $snps{$_});
    }
    $groups{$_} = \%hash; #update the reference
  }

  for(keys %snpsIn){
    if(!defined($groups{$_})){
      $groups{$_} = {}; #empty hash
    }
    my %hash = %{$groups{$_}};
    if(defined($snpIntronStarts{$_})){
      $hash{'intron+'} = join(';', $snpIntronStarts{$_}, $snpIntronEnds{$_}, $snpsIn{$_});
    }
    $groups{$_} = \%hash; #update the reference
  }

  for(keys %snpsNeg){
    if(!defined($groups{$_})){
      $groups{$_} = {}; #empty hash
    }
    my %hash = %{$groups{$_}};
    if(defined($snpNegExonStarts{$_})){
      $hash{'exon-'} = join(';', $snpNegExonStarts{$_}, $snpNegExonEnds{$_}, $snpsNeg{$_});
    }
    $groups{$_} = \%hash;
  }
  
  for(keys %snpsNegIn){
    if(!defined($groups{$_})){
      $groups{$_} = {}; #empty hash
    }
    my %hash = %{$groups{$_}};
    if(defined($snpNegIntronStarts{$_})){
      $hash{'intron-'} = join(';', $snpNegIntronStarts{$_}, $snpNegIntronEnds{$_}, $snpsNegIn{$_});
    }
    $groups{$_} = \%hash;
  }

  return \%groups;
}

sub getGroupedSnpInfoByType{
  my ($groupsRef, $pos, $type) = @_;
  #print  "Getting SNV $pos for type $type\n";
  my %groups = %$groupsRef;
  if(defined($groups{$pos})){
    my %snps = %{$groups{$pos}};
    if(defined($snps{$type})){
       return $snps{$type};
    }
  }
  return ''; #empty info

}

sub calSplicingEventNev
{
  #print "Splicing\n";
  my ($spsRef, $bedRef, $chr, $spEventsListRef, $gSnpRef, $gSnpKey, $nevCutoffLower, $nevCutoffUpper) = @_;
  
  # gene level Snps information for splicing NEV calculation 
  my ($geneSnpChrRef) = getListByKeyChr($gSnpRef, $gSnpKey, $chr);
  my %geneSnps = %$geneSnpChrRef;
  my %spHash = (); #store the updated results  

  my %spEventsList = %$spEventsListRef;
  my %spConstExons = ();

  foreach(keys %spEventsList){
    if(defined($spEventsList{$_}->{'type'})){
      my $tag = $spEventsList{$_}->{'type'};
      if(checkSupportedType($tag)){
        #print "Loading constitutive exons for gene $_ with $tag\n";
        $spConstExons{$tag} = getConstitutiveExonsByChr($spEventsList{$_}, $chr);
      }
    }
    else{ die "Error parsing event: no type available for $_\n"; }
  }

  my %allGeneSpSnps = %$spsRef;
  for(keys %allGeneSpSnps){
    my $gene = $_;
    
    my %geneConstRatio = (
     'anno' => undef,
     'rna' => undef,
     'est' => undef,
    );
    #pre-calculate all the geneConstRatios
    for my $t (keys %spConstExons){
      if(defined($spConstExons{$t})){
        my %chrCE = %{$spConstExons{$t}};

        if(defined($chrCE{$gene})){
          my $constExonSet = $chrCE{$gene};   
          $geneConstRatio{$t} = calConstRatio($constExonSet, $bedRef);
          #print "$t: $gene const ratio: $geneConstRatio{$t}\n";

        } #get the constitutive ratio if there is event evidence for this gene
      }
    }
    my $groupsRef = groupGeneSnps($geneSnps{$gene});

    my @allEvents = split('\t', $allGeneSpSnps{$gene});
    foreach(@allEvents){
     my ($snpPos, $eRegion, $lRegion, $rRegion, $strand, $additional, $tag) = split(';', $_);
     my $groupSnpInfo = getGroupedSnpInfoByType($groupsRef, $snpPos,"exon".$strand);
     if($groupSnpInfo eq ''){ #no exon info
       $groupSnpInfo = getGroupedSnpInfoByType($groupsRef, $snpPos,"intron".$strand);
     }

     if($groupSnpInfo ne ''){ #there is information
       # refine (intersect) the event region $eRegion as needed
       my ($s, $e, $transIds) = split(';', $groupSnpInfo);
       my ($eStart, $eEnd) = split(':', $eRegion);
       
       # do intersection if they overlap
       if($eStart <= $e && $eEnd >= $s){
         #print "Intersect! $eStart,$eEnd with $s, $e\n";
	 if($eStart < $s){ $eStart = $s; }
	 if($eEnd > $e){ $eEnd = $e; }
       }
       #print "Effective length: ".($eEnd-$eStart+1)."\n";
       if(!defined($geneConstRatio{$tag})){
         print "Warning: no const ratio for $tag for $gene\n $allGeneSpSnps{$gene}\n";
         last;
       }
       my $nev = calSpNev($eStart, $eEnd, $lRegion, $rRegion, $bedRef, $geneConstRatio{$tag}); 
       if($nev>$nevCutoffLower && $nev < $nevCutoffUpper){
         #print "We want this NEV: $nev, $_\n";
	 $spHash{$gene} .= join(";", $nev, $snpPos, $eRegion, $lRegion, $rRegion, $strand, $tag)."\t";
       }else{
         #print "We dont want this NEV: $nev, $_\n";
       }
     }else{
       print "WARNING: SNP $snpPos $tag event does not match $gene: $_\n";
       #exit;
     }
    }
  }
  return \%spHash;
}

sub calConstRatio
{
  my ($constExonSet, $bedRef) = @_;
  my @allConstExons = split(';', $constExonSet);
  my ($readCount, $effLen) = (0, 0);
  foreach(@allConstExons){
    my ($s, $e) = split('-', $_);
    my ($r, $l) = getEffReadSumLength($bedRef, $s, $e);
    #print "$_: reads: $r, length: $l\n";
    $readCount += $r;
    $effLen += $l;
  }
  if($effLen == 0){ 
    print "Warning: a gene without constExonSet reads: $constExonSet\n"; 
    return 0;
  }
 
  #print "const read: $readCount const len: $effLen\n";

  return $readCount/$effLen;
}

sub calSpNev
{
  my ($es, $ee, $lRegion, $rRegion, $bedRef, $constExonRatio) = @_;
  my ($ls, $le) = split(':', $lRegion);
  my ($rs, $re) = split(':', $rRegion);
  my ($nev, $nev2, $altReads, $altLen) = (-1, -1, 0, 0);
    
  # possible alt regions
  ($altReads, $altLen) = getEffReadSumLength($bedRef, $es, $ee);

  #use the event only to calculate Nev
  #cal psi based on consituent exon  
  if($constExonRatio > 0 && $altLen >0){
    $nev = ($altReads/$altLen)/$constExonRatio;
  }
  
  #calculate the ratio based on the flanking regions
  if($ls != -1 && $rs !=-1){
    # flanking regions
    my ($c, $l) = getEffReadSumLength($bedRef, $ls, $le); 
    my ($c2, $l2) = getEffReadSumLength($bedRef, $rs, $re); 
    $c += $c2; $l += $l2;
    if($l > 0 && $altLen >0){
      $nev2 = ($altReads/$altLen)/($c/$l);
    }

  }
 
  #get the smaller one (but has to >0)
  if($nev2 > 0 && $nev2 < $nev){
   $nev = $nev2;
  }
  return $nev;
}

sub calAltEventNev
{
  my ($powAltsRef, $bedRef, $chr, $nevCutoffLower, $nevCutoffUpper) = @_;
  my %allGeneSnps = %$powAltsRef;
  for(keys %allGeneSnps){
     my $gene = $_;
     my $updatedEvents = '';
     my @allEvents = split('\t', $allGeneSnps{$_});
     foreach(@allEvents){
       my ($type,$pos,$altRegion,$constRegion) = split(',', $_);
       my ($altL, $altR) = split('-', $altRegion);
       my ($constL, $constR) = split('-', $constRegion);
       my ($altRead, $altLen) = getEffReadSumLength($bedRef, $altL, $altR);
       my ($constRead, $constLen) = getEffReadSumLength($bedRef, $constL, $constR);
       my ($altRatio, $constRatio) = (0, 0);
       if($altLen >0){
         $altRatio = $altRead/$altLen;
       }
       if($constLen > 0){
         $constRatio = $constRead/$constLen;
       }
       my $nev = 0; #normalized expression value, similar to psi
       if($constRatio>0){
         $nev = $altRatio/$constRatio;
       }
       if($nev > $nevCutoffLower && $nev < $nevCutoffUpper){
          $updatedEvents .= "$type,$pos,$nev,$altRegion,$constRegion\t";
	  #print "$gene\t$type,$pos,$nev,$altRegion,$constRegion\n";
       }

     }
     $allGeneSnps{$_} = $updatedEvents;
  }
  return \%allGeneSnps;
}

#################################################
sub setSnpEvents{
  my ($geneSnpRef, $altRef, $splicingRef) = @_;
  my ($gPowSnpAltRef, $gSnpAltRef) = setSnpAltEvents($geneSnpRef, $altRef); #match snps with Alt Events
  my ($gPowSnpSpRef, $gSnpSpRef) = setSnpSplicingEvents($geneSnpRef, $splicingRef); #match snps with Splicing Events
  
  my %snpEvents = (
    'powSnpAlt' => $gPowSnpAltRef,
    'snpAlt' => $gSnpAltRef,
    'powSnpSp' => $gPowSnpSpRef,
    'snpSp' => $gSnpSpRef,
  );
  return \%snpEvents;
}
#################################################
## the following sub is to match the Snps with the Alt Events
sub setSnpAltEvents{
  my ($geneSnpRef, $altRef) = @_;

  my @snpEvents = ();
  my @powSnpEvents = ();
  for(my $i=0; $i<=$CHRNUM; $i++){
    push @snpEvents, {};
    push @powSnpEvents, {};
  }
  my $gPowSnpAltEndsRef = \@powSnpEvents;
  my $gSnpAltEndsRef = \@snpEvents;

  ## attributes for each gene in a chromosome of the snpEvents
  # 'AltEnd', 'AltSp', 'GeneLv' = 1, or 0
  $gPowSnpAltEndsRef = snpVsAltEvents($gPowSnpAltEndsRef, $geneSnpRef, 'gPowSnps', $altRef);
  $gSnpAltEndsRef = snpVsAltEvents($gSnpAltEndsRef, $geneSnpRef, 'gSnps', $altRef);

  return ($gPowSnpAltEndsRef, $gSnpAltEndsRef);
}

# matching snps of a particular type (gSnps or gPowSnps) with Alt Ends
sub snpVsAltEvents
{
  my ($snpEventRef, $geneSnpRef, $geneSnpKey, $altEventRef) = @_;
  #print "Gene level SNP ($geneSnpKey) VS Alternative transcript ends (5', 3')\n";
  my @snpEvents = @$snpEventRef;

  for (my $i=1; $i<=$CHRNUM; $i++){
    my ($geneRef) = getListByKeyChr($geneSnpRef, $geneSnpKey, $i); 
    my $geneChrRef = getChrGeneSnpsSorted($geneSnpRef, $geneSnpKey, $i);
    my @chrGenes = @$geneChrRef;

    # Alt 5', 3' transcript ends information
    my %alts = %{getAltEndsListByChr($altEventRef, $i)};
    
    #my %genesPrinted = (); #to store genes printed already in order not to double-print
    if(@chrGenes){
      #printChr($i); print "\n";
      foreach(@chrGenes){
        my @allGenes = split('\t', $_);
        foreach(@allGenes){
	  #get the snp information
	  
          my %snpPosTabu = (); # to avoid duplicate processing of snps for this particular gene
	  my @geneMatches = split('\t', $geneRef->{$_});
	  for(@geneMatches){
	    my ($snpPos, $matchInfo, $geneName, $txStart, $id, $regStart, $regEnd) = split(';', $_);
            if(defined($snpPosTabu{$snpPos})){
	      next; # skip all the following processing
	    }
	    $snpPosTabu{$snpPos}=1; #set the tabu list
	    # just check for printing debug
	    #if(!defined($genesPrinted{$geneName})){
	    #  print $geneName."\n";
	    #  $genesPrinted{$geneName} = 1;
	    #}else{ $genesPrinted{$geneName} += 1; }
            
	    my $snpAltInfoAdd = '';
            if(defined($alts{$geneName})){ #only when there are events defined for this gene
	      $snpAltInfoAdd = matchSnpPoswithAltEvents($snpPos, $alts{$geneName}); 
	    }
	    if($snpAltInfoAdd ne ''){
	       #print "$snpAltInfoAdd\n";
	       my %snpAltHash = ();
               if(defined($snpEvents[$i])){
	         # there is information originally, use it
		 %snpAltHash = %{$snpEvents[$i]};
               }
	       if(!defined($snpAltHash{$geneName})){
	         $snpAltHash{$geneName} = $snpAltInfoAdd;
	       }else{
	         $snpAltHash{$geneName} .= $snpAltInfoAdd;
	       }
	       $snpEvents[$i] = \%snpAltHash; #get back to the reference
	    }
	  } #endof foreach(@geneMatches) 
        } #endof foreach (@allGenes)
      } #endof foreach(@chrGenes)
    }
  } #end of chromosome

  return \@snpEvents;
}

sub matchSnpPoswithAltEvents
{
  my ($pos, $altRef) = @_;
  my %alts = %$altRef;
  my $snpInfoToAdd = '';

  my @allTypes = ('5+', '5-', '3+', '3-');
  for my $type (@allTypes){
    if(defined($alts{$type})){ #exists
      my %hash = %{$alts{$type}};
      for my $altKeyPos (keys %hash){
	
	if($type eq '5+' || $type eq '3-'){ #key is larger than value
          if($altKeyPos >= $pos){ #need to check
            my @altPos = split(';', $hash{$altKeyPos});
	    @altPos = sort { $a <=> $b } @altPos; #sorted in ascending order
	    if(@altPos > 1){ # there are alternative splicing
              my $pi = 0;
	      while($pi<@altPos-1){
	        if($altPos[$pi] <= $pos && $pos <= $altPos[$pi+1]-1){ # a hit
		  #store both alt and const regions
		  $snpInfoToAdd .= "$type,$pos,$altPos[$pi]-".($altPos[$pi+1]-1).",$altPos[-1]-$altKeyPos\t";
		  #print "$snpInfoToAdd as $pos hit key $altKeyPos: @altPos\n";
		  last;
		}
	        $pi++;
	      }

	    } # if @altPos <= 1, no alternative start/end for 5' or 3'
	  }
	
	}else{ #'5-' or '3+': key is smaller than value
          if($altKeyPos <= $pos){ #need to check
            my @altPos = split(';', $hash{$altKeyPos});
	    @altPos = sort { $a <=> $b } @altPos; #sorted in ascending order
	    if(@altPos > 1){ # there are alternative splicing
              my $pi = 1;
	      while($pi<@altPos){
	        if($altPos[$pi-1]+1 <= $pos && $pos <= $altPos[$pi]){ # a hit
		  $snpInfoToAdd .= "$type,$pos,".($altPos[$pi-1]+1)."-$altPos[$pi],$altKeyPos-$altPos[0]\t";
		  #print "$snpInfoToAdd as $pos hit key $altKeyPos: @altPos\n";
		  last;
		}
	        $pi++;
	      }
	    } # if @altPos <= 1, no alternative start/end for 5' or 3'
	  }
	
	}
      }
    }
  }
  return $snpInfoToAdd;
}

#################################################
## the following sub is to match the Snps with the Splicing Events

sub setSnpSplicingEvents{
  my ($geneSnpRef, $splicingRef) = @_;

  my @snpEvents = ();
  my @powSnpEvents = ();
  for(my $i=0; $i<=$CHRNUM; $i++){
    push @snpEvents, {};
    push @powSnpEvents, {};
  }
  my $gPowSnpSplicingRef = \@powSnpEvents;
  my $gSnpSplicingRef = \@snpEvents;

  ## attributes for each gene in a chromosome of the snpEvents
  # 'AltEnd', 'AltSp', 'GeneLv' = 1, or 0
  $gPowSnpSplicingRef = snpVsSplicingEvents($gPowSnpSplicingRef, $geneSnpRef, 'gPowSnps', $splicingRef);
  $gSnpSplicingRef = snpVsSplicingEvents($gSnpSplicingRef, $geneSnpRef, 'gSnps', $splicingRef);

  return ($gPowSnpSplicingRef, $gSnpSplicingRef);
}


# matching snps of a particular type (gSnps or gPowSnps) with internal exon splicing events
sub snpVsSplicingEvents
{
  my ($snpEventRef, $geneSnpRef, $geneSnpKey, $SplicingEventsRef) = @_;
  #print "Gene level SNP ($geneSnpKey) VS Splicing events\n";
  my @snpEvents = @$snpEventRef;

  for (my $i=1; $i<=$CHRNUM; $i++){
    my ($geneRef) = getListByKeyChr($geneSnpRef, $geneSnpKey, $i); 
    my $geneChrRef = getChrGeneSnpsSorted($geneSnpRef, $geneSnpKey, $i);
    my @chrGenes = @$geneChrRef;
   
    my ($spRef, $spIdx) = getListByKeyChr($SplicingEventsRef, 'events', $i);
    my %splicing = %$spRef; 
    #my %genesPrinted = (); #to store genes printed already in order not to double-print

    if(@chrGenes){
      #printChr($i); print "\n";
      foreach(@chrGenes){
        my @allGenes = split('\t', $_);
        foreach(@allGenes){ #each element is a gene name
	  #get the snp information
	    
          my %snpPosTabu = (); # to avoid duplicate processing of snps for this particular gene
	  my @geneMatches = split('\t', $geneRef->{$_});
	  for(@geneMatches){
	    my ($snpPos, $matchInfo, $geneName, $txStart, $id, $regStart, $regEnd) = split(';', $_);
            if(defined($snpPosTabu{$snpPos})){
	      next; # skip all the following processing
	    }
	    $snpPosTabu{$snpPos}=1; #set the tabu list
	    # just check for printing debug
	    #if(!defined($genesPrinted{$geneName})){
	    #  print $geneName."\n";
	    #  $genesPrinted{$geneName} = 1;
	    #}else{ $genesPrinted{$geneName} += 1; }
	    
	    my $snpSpInfoAdd = '';
            if(defined($splicing{$geneName})){ #only when there are events defined for this gene
	      $snpSpInfoAdd = matchSnpPoswithSplicingEvents($snpPos, $splicing{$geneName}); 
	    }
	    if($snpSpInfoAdd ne ''){
	       #print "$snpSpInfoAdd\n";
	       my %snpSpHash = ();
               if(defined($snpEvents[$i])){
	         # there is information originally, use it
		 %snpSpHash = %{$snpEvents[$i]};
               }
	       if(!defined($snpSpHash{$geneName})){
	         $snpSpHash{$geneName} = $snpSpInfoAdd;
	       }else{
	         $snpSpHash{$geneName} .= $snpSpInfoAdd;
	       }
	       $snpEvents[$i] = \%snpSpHash; #get back to the reference
	    }
	  } #endof foreach(@geneMatches) 
        } #endof foreach (@allGenes)
      } #endof foreach(@chrGenes)
    }
  } #end of chromosome

  return \@snpEvents;
}

sub matchSnpPoswithSplicingEvents
{
  my ($pos, $splicing) = @_;
  my $snpInfoToAdd = '';
  my @events = split('\t', $splicing);
  foreach(@events){
    my ($eRegion, $lRegion, $rRegion, $strand, $additional, $tag) = split(';', $_);
    my ($eStart, $eEnd) = split(':', $eRegion);
    if($eStart <= $pos && $pos <= $eEnd){ # a snp match!
      $snpInfoToAdd .= $pos.";".$_."\t";
      #print "Add event: $_ [$eStart, $eEnd] to $pos\n";
    }
    
  }
  return $snpInfoToAdd;
}



################ minor auxiliary (mainly for print outs and debugs) ####
# print out the gene snps results for certain type (powerful or ordinary snps)
sub printGetGeneSnpsResults
{
  my ($geneSnpRef, $geneSnpKey, $snpRef, $snpKey, $snvPValueCutoff) = @_;
  print "Gene level SNP ($geneSnpKey) VS transcript results\n";

  for (my $i=1; $i<=$CHRNUM; $i++){
    my ($geneRef) = getListByKeyChr($geneSnpRef, $geneSnpKey, $i); 
    my $geneChrRef = getChrGeneSnpsSorted($geneSnpRef, $geneSnpKey, $i);
    my ($snpInfoRef) = getListByKeyChr($snpRef, $snpKey, $i);
    my %snps = %$snpInfoRef; #snps information
    my @genes = @$geneChrRef;
    my %genesPrinted = (); #to store genes printed already in order not to double-print
    if(@genes){
      printChr($i); print "\n";
      #print "@genes\t";
      foreach(@genes){
        my @allGenes = split('\t', $_);
        foreach(@allGenes){
	  #get the snp information
	  my @geneMatches = split('\t', $geneRef->{$_});
	  for(@geneMatches){
	    my ($snpPos, $matchInfo, $geneName, $txStart, $id, $regStart, $regEnd) = split(';', $_);
	    if(!defined($genesPrinted{$geneName})){
	      print $geneName."\n";
	      $genesPrinted{$geneName} = 1;
	    }else{ $genesPrinted{$geneName} += 1; }
	    #print $snps{$snpPos}."\n";
	    my @allSnpInfo = split(';', $snps{$snpPos}); #separate by ;, if there are multiple snps at the same position
            foreach(@allSnpInfo){
	      my $toPrint = $matchInfo."\t".$geneName."\t".$id.":".$regStart."-".$regEnd."\n";
	      if($geneSnpKey eq 'gPowSnps'){
	        #$p."\t".$pos."\t".$alleles."\t".$snpName."\t".$refAl."\t".$altAl.";";
		my ($p, $pos, $alleles, $snpId) = getSnpInfo($_);
	        if($p <= $snvPValueCutoff){
	          print "$snpId,$p,$alleles,$pos\t".$toPrint;
	        }
	      }else{
	        print $_."\t".$toPrint;
	      }
	    }
	  }
        }
      }
      print "\n";
    }
  }

}

sub printSnpEventsResultsByType
{
  my ($snpEventsRef, $key) = @_;
  # print the snpEvents out
  #my $key = 'powSnpAlt';
  my $testEventsRef = $snpEventsRef->{$key};
  my @testEvents = @$testEventsRef;
  for(my $i=1; $i<=$CHRNUM; $i++){
    if(defined($testEvents[$i])){
      printChr($i); print "\n";
      my %geneHash = %{$testEvents[$i]};
      my @genes = keys %geneHash;
      if(@genes>0){
        foreach(@genes){
          print "$_\n";
          print $geneHash{$_}."\n";
        }
      }
    }
  }
}
1;
