//$Id$
//functionality of the periodic boundary condition manager


/*
 * pic_bc_periodic.cpp
 *
 *  Created on: Sep 25, 2017
 *      Author: vtenishe
 */


#include "pic.h"

//originaly requsted limits of the computational domain
double PIC::BC::ExternalBoundary::Periodic::xminOriginal[3]={0.0,0.0,0.0};
double PIC::BC::ExternalBoundary::Periodic::xmaxOriginal[3]={0.0,0.0,0.0};

//the actual limits of the computational part (without "ghost" block) of the dimain
double PIC::BC::ExternalBoundary::Periodic::xminDomain[3]={0.0,0.0,0.0};
double PIC::BC::ExternalBoundary::Periodic::xmaxDomain[3]={0.0,0.0,0.0};

//the period length in each dimention
double PIC::BC::ExternalBoundary::Periodic::L[3]={0.0,0.0,0.0};

double PIC::BC::ExternalBoundary::Periodic::HighestBoundaryResolution;
double PIC::BC::ExternalBoundary::Periodic::BoundaryDx[3]={0.0,0.0,0.0}; //extension length outside the oringal user requested domain
PIC::BC::ExternalBoundary::Periodic::fUserResolutionFunction PIC::BC::ExternalBoundary::Periodic::localUserResolutionFunction=NULL;

PIC::BC::ExternalBoundary::Periodic::cBlockPairTable *PIC::BC::ExternalBoundary::Periodic::BlockPairTable=NULL;
int PIC::BC::ExternalBoundary::Periodic::BlockPairTableLength=0;

//thecommunication channel for message exchange between MPI processes
CMPI_channel PIC::BC::ExternalBoundary::Periodic::pipe;

//update data between the 'real' and 'ghost' blocks
void PIC::BC::ExternalBoundary::Periodic::UpdateData() {
  int i,j,k,iBlockPair,RealBlockThread,GhostBlockThread;

  //loop through all block pairs
  for (iBlockPair=0;iBlockPair<BlockPairTableLength;iBlockPair++) {
    GhostBlockThread=BlockPairTable[iBlockPair].GhostBlock->Thread;
    RealBlockThread=BlockPairTable[iBlockPair].RealBlock->Thread;

    if ((GhostBlockThread==PIC::ThisThread)||(RealBlockThread==PIC::ThisThread)) {
      if (GhostBlockThread==RealBlockThread) {
        ExchangeBlockDataLocal(BlockPairTable[iBlockPair]);
      }
      else {
        ExchangeBlockDataMPI(BlockPairTable[iBlockPair]);
      }
    }
  }
}

//process the data update for the 'ghost' block
void PIC::BC::ExternalBoundary::Periodic::ExchangeBlockDataLocal(cBlockPairTable& BlockPair) {
  int i,j,k,idim;
  long int ptr,NextPtr;
  double *x;

  cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>  *GhostBlock=BlockPair.GhostBlock;
  cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>  *RealBlock=BlockPair.RealBlock;
  
  double dx[3]; //displacement from realblock to ghostbloock
  for (int i=0;i<3;i++) dx[i]=RealBlock->xmin[i]-GhostBlock->xmin[i];
  
  //attach particle list from the 'ghost' block to the 'real block'
  for (k=0;k<_BLOCK_CELLS_Z_;k++) for (j=0;j<_BLOCK_CELLS_Y_;j++) for (i=0;i<_BLOCK_CELLS_X_;i++) if ((ptr=GhostBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)])!=-1) {
    //find the last particle in the block
    NextPtr=PIC::ParticleBuffer::GetNext(ptr);

    //shift the location of the first particle
    for (idim=0,x=PIC::ParticleBuffer::GetX(ptr);idim<3;idim++) x[idim]+=dx[idim];

    if (NextPtr!=-1) {
      //the list containes more than one particle => process them
      do {
        ptr=NextPtr;

        //shift location of the particle
        for (idim=0,x=PIC::ParticleBuffer::GetX(ptr);idim<3;idim++) x[idim]+=dx[idim];

        //get the next particle in the list
        NextPtr=PIC::ParticleBuffer::GetNext(ptr);
      }
      while (NextPtr!=-1);
    }

    //reconnect the lists
    PIC::ParticleBuffer::SetNext(RealBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)],ptr);

    if (RealBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]!=-1) {
      PIC::ParticleBuffer::SetPrev(ptr,RealBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]);
    }

    RealBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]=GhostBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)];
    GhostBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]=-1;
  }
}

void PIC::BC::ExternalBoundary::Periodic::ExchangeBlockDataMPI(cBlockPairTable& BlockPair) {
  int i,j,k;
  long int ptr,NewParticle,NextPtr;

  int GhostBlockThread=BlockPair.GhostBlock->Thread;
  int RealBlockThread=BlockPair.RealBlock->Thread;

  cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>  *GhostBlock=BlockPair.GhostBlock;
  cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>  *RealBlock=BlockPair.RealBlock;

  double dx[3]; //displacement from RealBlock to GhostBlock
  for (int iDim=0; iDim<3; iDim++) dx[iDim]=RealBlock->xmin[iDim]-GhostBlock->xmin[iDim];

  //the list of signals
  const int NewCellCoordinatesSignal=0;
  const int NewParticelDataSignal=1;
  const int ParticleSendCompleteSignal=2;
  int Signal;

  //send the particles associated with the block
  if (GhostBlockThread==PIC::ThisThread) {
    //send out all particles
    //redirect the send pipe buffers
    pipe.RedirectSendBuffer(RealBlockThread);

    for (k=0;k<_BLOCK_CELLS_Z_;k++) for (j=0;j<_BLOCK_CELLS_Y_;j++) for (i=0;i<_BLOCK_CELLS_X_;i++) if ((ptr=GhostBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)])!=-1) {
      pipe.send(NewCellCoordinatesSignal);
      pipe.send(i);
      pipe.send(j);
      pipe.send(k);

      while (ptr!=-1) {
        pipe.send(NewParticelDataSignal);
        pipe.send((char*)PIC::ParticleBuffer::GetParticleDataPointer(ptr),PIC::ParticleBuffer::ParticleDataLength);

        NextPtr=PIC::ParticleBuffer::GetNext(ptr);
        PIC::ParticleBuffer::DeleteParticle_withoutTrajectoryTermination(ptr,true);
        ptr=NextPtr;
      }
   
      GhostBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]=-1;
    }

    pipe.send(ParticleSendCompleteSignal);
  }
  else {
    //recieve particles
    char tempParticleData[PIC::ParticleBuffer::ParticleDataLength];
    double *x;

    pipe.RedirectRecvBuffer(GhostBlockThread);
    Signal=pipe.recv<int>(GhostBlockThread);

    if (Signal!=ParticleSendCompleteSignal) {
      do {
        switch (Signal) {
        case NewCellCoordinatesSignal:
          i=pipe.recv<int>(GhostBlockThread);
          j=pipe.recv<int>(GhostBlockThread);
          k=pipe.recv<int>(GhostBlockThread);
          break;

        case NewParticelDataSignal:
          pipe.recv(tempParticleData,PIC::ParticleBuffer::ParticleDataLength,GhostBlockThread);

          //shift location of the particle
          x=PIC::ParticleBuffer::GetX((PIC::ParticleBuffer::byte *)tempParticleData);
          for (int idim=0;idim<3;idim++) x[idim]+=dx[idim];

          //generate a new particle
          NewParticle=PIC::ParticleBuffer::GetNewParticle(RealBlock->block->FirstCellParticleTable[i+_BLOCK_CELLS_X_*(j+_BLOCK_CELLS_Y_*k)]);
          PIC::ParticleBuffer::CloneParticle(PIC::ParticleBuffer::GetParticleDataPointer(NewParticle),(PIC::ParticleBuffer::byte *)tempParticleData);
          break;

        default:
          exit(__LINE__,__FILE__,"Error: unknown signal");
        }

        Signal=pipe.recv<int>(GhostBlockThread);
      }
      while (Signal!=ParticleSendCompleteSignal);
    }
  }

  //flush the pipe
  pipe.flush();
}


cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>* PIC::BC::ExternalBoundary::Periodic::findCorrespondingRealBlock(cTreeNodeAMR<PIC::Mesh::cDataBlockAMR>* GhostPtr) {
  double  xGhostCenter[3], xTrueCenter[3];

  // find location of the center of the true block                                                                                            
  for (int i=0;i<3;i++) {
    xGhostCenter[i]=0.5*(GhostPtr->xmin[i]+GhostPtr->xmax[i]);
    xTrueCenter[i]=xGhostCenter[i];

    if (xGhostCenter[i]>xmaxOriginal[i]) {
      xTrueCenter[i]-=L[i];
    }
    else if (xGhostCenter[i]<xminOriginal[i]) {
      xTrueCenter[i]+=L[i];
    }
  }

  return PIC::Mesh::mesh.findTreeNode(xTrueCenter);
}

//Initialize the periodic boundary manager
void PIC::BC::ExternalBoundary::Periodic::Init(double* xmin,double* xmax,double (*localRequestedResolutionFunction)(double*)) {
  int idim;

  //init the pipe for message exchange between MPI processes
  pipe.init(1000000);

  pipe.openSend(0);
  pipe.openRecv(0);

  //save the initial and modified domain limits
  for (idim=0;idim<3;idim++) {
    xminOriginal[idim]=xmin[idim],xmaxOriginal[idim]=xmax[idim];
    L[idim]=xmax[idim]-xmin[idim];
  }

  localUserResolutionFunction=localRequestedResolutionFunction;
  GetBoundaryExtensionLength();
  

  if (PIC::ThisThread==0) printf("$PREFIX: BoundaryDx: ");

  for (idim=0;idim<3;idim++) {
    xminDomain[idim]= xminOriginal[idim]-BoundaryDx[idim];
    xmaxDomain[idim]= xmaxOriginal[idim]+BoundaryDx[idim];
    if (PIC::ThisThread==0) printf(" %f ",BoundaryDx[idim]);
  }

  if (PIC::ThisThread==0) printf("\n");
  
  //initiate the mesh  
  PIC::Mesh::mesh.init(xminDomain,xmaxDomain,ModifiedLocalResolution);
}

void PIC::BC::ExternalBoundary::Periodic::InitBlockPairTable(){
  std::vector<cTreeNodeAMR<PIC::Mesh::cDataBlockAMR> *> GhostBlockVector;
  
  PopulateGhostBlockVector(GhostBlockVector,NULL);
  BlockPairTableLength=GhostBlockVector.size();

  printf("$PREFIX: Ghost block pair number: %d\n",BlockPairTableLength);
  BlockPairTable = new cBlockPairTable[BlockPairTableLength];

  //populate the blockpair                                                                                        
  for (int iPair=0; iPair<BlockPairTableLength; iPair++) {
    BlockPairTable[iPair].GhostBlock = GhostBlockVector[iPair];
    BlockPairTable[iPair].RealBlock = findCorrespondingRealBlock(BlockPairTable[iPair].GhostBlock);
  }
}


double PIC::BC::ExternalBoundary::Periodic::ModifiedLocalResolution(double* x) {
  for (int iDim=0;iDim<3;iDim++) {
    if ((x[iDim]<xminDomain[iDim]+2*BoundaryDx[iDim]) || (x[iDim]>xmaxDomain[iDim]-2*BoundaryDx[iDim])) return HighestBoundaryResolution;
  }

  return localUserResolutionFunction(x);
}

double PIC::BC::ExternalBoundary::Periodic::GetHighestRequestedBoundaryResolution(int SamplingPoints) {
  double xTest[3],x0[3],e0[3],e1[3],de0=0.0,de1=0.0,c0,c1,locRes,res=xmaxOriginal[0]-xminOriginal[0];
  int iface,i,j,idim,iTest;

  //select the number of test points in each dimentions
  int nTotalTests=(SamplingPoints>25) ? SamplingPoints : 1024;

  //geometry information
  static const double FaceX0Table[6][3]={{0,0,0},{1,0,0}, {0,0,0},{0,1,0}, {0,0,0},{0,0,1}};
  static const double FaceE0Table[6][3]={{0,1,0},{1,1,0}, {1,0,0},{1,1,0}, {1,0,0},{1,0,1}};
  static const double FaceE1Table[6][3]={{0,0,1},{1,0,1}, {0,0,1},{0,1,1}, {0,1,0},{0,1,1}};

  double dxOriginal[3]={xmaxOriginal[0]-xminOriginal[0],xmaxOriginal[1]-xminOriginal[1],xmaxOriginal[2]-xminOriginal[2]};

  for (iface=0;iface<6;iface++) {
    for (idim=0;idim<3;idim++) {
      x0[idim]=xminOriginal[idim]+FaceX0Table[iface][idim]*dxOriginal[idim];

      e0[idim]=xminOriginal[idim]+FaceE0Table[iface][idim]*dxOriginal[idim]-x0[idim];
      de0+=pow(e0[idim],2);

      e1[idim]=xminOriginal[idim]+FaceE1Table[iface][idim]*dxOriginal[idim]-x0[idim];
      de1+=pow(e1[idim],2);
    }

    de0=sqrt(de0);
    de1=sqrt(de1);

    for (iTest=0;iTest<nTotalTests;iTest++) {
      //get the test location
      for (idim=0,c0=rnd(),c1=rnd();idim<3;idim++) xTest[idim]=x0[idim]+c0*e0[idim]+c1*e1[idim];

      //get local requster resolution
      locRes=localUserResolutionFunction(xTest);
      if (locRes<res) res=locRes;
    }
  }

  return res;
}


void PIC::BC::ExternalBoundary::Periodic::GetBoundaryExtensionLength() {
  double level[3];
  int nBlkArr[3]={_BLOCK_CELLS_X_,_BLOCK_CELLS_Y_,_BLOCK_CELLS_Z_};
  double dx[3];

  HighestBoundaryResolution = PIC::BC::ExternalBoundary::Periodic::GetHighestRequestedBoundaryResolution(1024);


  for (int i=0;i<3;i++){
    dx[i]=(xmaxOriginal[i]-xminOriginal[i])/nBlkArr[i];
  }

  double rCell = sqrt(dx[0]*dx[0]+dx[1]*dx[1]+dx[2]*dx[2]);
  for (int i=0;i<3;i++) dx[i]/=rCell;

  for (int iDim=0;iDim<3;iDim++){
    level[iDim]=log2((xmaxOriginal[iDim]-xminOriginal[iDim]+2.*HighestBoundaryResolution*dx[iDim]*nBlkArr[iDim])/(2.*HighestBoundaryResolution*dx[iDim]*nBlkArr[iDim]));
  }

  double maxLevel= *std::max_element(level,level+3);
  int nLevel=(int)ceil(maxLevel);

  printf("$PREFIX: max level at boundary:%d\n",nLevel);

  for(int i=0;i<3;i++){
    BoundaryDx[i]=(xmaxOriginal[i]-xminOriginal[i])/(pow(2.,nLevel)-1.)/2.;
  }
}


void PIC::BC::ExternalBoundary::Periodic::PopulateGhostBlockVector(std::vector<cTreeNodeAMR<PIC::Mesh::cDataBlockAMR> *> &BlockVector, cTreeNodeAMR<PIC::Mesh::cDataBlockAMR> * startNode=NULL){
  int NullNodeNum=0;

  if (startNode==NULL) startNode=PIC::Mesh::mesh.rootTree;

  for (int i=0;i<8;i++){
    if (startNode->downNode[i]!=NULL) {
      PIC::BC::ExternalBoundary::Periodic::PopulateGhostBlockVector(BlockVector,startNode->downNode[i]);
    }else{
      NullNodeNum++;
    }
  }

  if ((NullNodeNum==8)&&(PIC::Mesh::mesh.ExternalBoundaryBlock(startNode)==_EXTERNAL_BOUNDARY_BLOCK_)) {
    BlockVector.push_back(startNode);
  }
}






