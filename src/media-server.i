%module medooze
%{
	
#include <string>
#include "../media-server/include/config.h"	
#include "../media-server/include/dtls.h"	
#include "../media-server/include/media.h"
#include "../media-server/include/rtp.h"
#include "../media-server/include/rtpsession.h"
#include "../media-server/include/DTLSICETransport.h"	
#include "../media-server/include/RTPBundleTransport.h"
#include "../media-server/include/mp4recorder.h"
#include "../media-server/src/vp9/VP9LayerSelector.h"

class StringFacade : private std::string
{
public:
	StringFacade(const char* str) 
	{
		std::string::assign(str);
	}
	StringFacade(std::string &str) : std::string(str)
	{
		
	}
	const char* toString() 
	{
		return std::string::c_str();
	}
};

class PropertiesFacade : private Properties
{
public:
	void SetProperty(const char* key,int intval)
	{
		Properties::SetProperty(key,intval);
	}

	void SetProperty(const char* key,const char* val)
	{
		Properties::SetProperty(key,val);
	}
};

class MediaServer
{
public:
	static void Initialize()
	{
		//Start DTLS
		DTLSConnection::Initialize();
	}
	static void EnableDebug(bool flag)
	{
		//Enable debug
		Log("-EnableDebug [%d]\n",flag);
		Logger::EnableDebug(flag);
	}
	
	static void EnableUltraDebug(bool flag)
	{
		//Enable debug
		Log("-EnableUltraDebug [%d]\n",flag);
		Logger::EnableUltraDebug(flag);
	}
	
	static StringFacade GetFingerprint()
	{
		return StringFacade(DTLSConnection::GetCertificateFingerPrint(DTLSConnection::Hash::SHA256).c_str());
	}
	
};

class StreamTransponder : 
	public RTPIncomingSourceGroup::Listener,
	public RTPOutgoingSourceGroup::Listener
{
public:
	StreamTransponder(RTPIncomingSourceGroup* incomingSource, RTPReceiver* incomingTransport, RTPOutgoingSourceGroup* outgoingSource,RTPSender* outgoingTransport)
	{
		//Store streams
		this->incomingSource = incomingSource;
		this->outgoingSource = outgoingSource;
		this->incomingTransport = incomingTransport;
		this->outgoingTransport = outgoingTransport;
		
		//Add us as listeners
		outgoingSource->AddListener(this);
		incomingSource->AddListener(this);
		
		//Request update on the incoming
		if (incomingTransport) incomingTransport->SendPLI(incomingSource->media.ssrc);
	}

	void Stop()
	{
		ScopedLock lock(mutex);
		
		//Stop listeneing
		if (outgoingSource) outgoingSource->RemoveListener(this);
		if (incomingSource) incomingSource->RemoveListener(this);
		
		//Remove sources
		outgoingSource = NULL;
		incomingSource = NULL;
		incomingTransport = NULL;
		outgoingTransport = NULL;
	}
	
	virtual ~StreamTransponder()
	{
		Log("~StreamTransponder()");
		//Stop listeneing
		Stop();
	}

	virtual void onRTP(RTPIncomingSourceGroup* group,RTPPacket* packet)
	{
		ScopedLock lock(mutex);
		
		//Double check
		if (!group || !packet)
			//Error
			return;
		
		//Check if it is an VP9 packet
		if (packet->GetCodec()==VideoCodec::VP9)
		{
			DWORD extSeqNum;
			bool mark;
			//Select layer
			if (!selector.Select(packet,extSeqNum,mark))
			       //Drop
			       return;
		       //Set them
		       packet->SetSeqNum(extSeqNum);
		       packet->SetSeqCycles(extSeqNum >> 16);
		       //Set mark
		       packet->SetMark(mark);
		}
		
		//Double check
		if (outgoingSource && outgoingTransport)
		{
			//Change ssrc
			packet->SetSSRC(outgoingSource->media.ssrc);
			//Send it on transport
			outgoingTransport->Send(*packet);
		}
	}
	
	virtual void onPLIRequest(RTPOutgoingSourceGroup* group,DWORD ssrc)
	{
		ScopedLock lock(mutex);
		
		//Request update on the incoming
		if (incomingTransport && incomingSource) incomingTransport->SendPLI(incomingSource->media.ssrc);
	}
	
	void SelectLayer(int spatialLayerId,int temporalLayerId)
	{
		ScopedLock lock(mutex);
		
		if (selector.GetSpatialLayer()<spatialLayerId)
			//Request update on the incoming
			if (incomingTransport && incomingSource) incomingTransport->SendPLI(incomingSource->media.ssrc);
		selector.SelectSpatialLayer(spatialLayerId);
		selector.SelectTemporalLayer(temporalLayerId);
	}
private:
	RTPOutgoingSourceGroup *outgoingSource;
	RTPIncomingSourceGroup *incomingSource;
	RTPReceiver* incomingTransport;
	RTPSender* outgoingTransport;
	VP9LayerSelector selector;
	Mutex mutex;
};

class StreamTrackDepacketizer :
	public RTPIncomingSourceGroup::Listener
{
public:
	StreamTrackDepacketizer(RTPIncomingSourceGroup* incomingSource)
	{
		//Store
		this->incomingSource = incomingSource;
		//Add us as RTP listeners
		this->incomingSource->AddListener(this);
		//No depkacketixer yet
		depacketizer = NULL;
	}

	virtual ~StreamTrackDepacketizer()
	{
		//Stop listeneing
		incomingSource->RemoveListener(this);
		//Delete depacketier
		delete(depacketizer);
	}

	virtual void onRTP(RTPIncomingSourceGroup* group,RTPPacket* packet)
	{
		//If depacketizer is not the same codec 
		if (depacketizer && depacketizer->GetCodec()!=packet->GetCodec())
		{
			//Delete it
			delete(depacketizer);
			//Create it next
			depacketizer = NULL;
		}
		//If we don't have a depacketized
		if (!depacketizer)
			//Create one
			depacketizer = RTPDepacketizer::Create(packet->GetMedia(),packet->GetCodec());
		//Ensure we have it
		if (!depacketizer)
			//Do nothing
			return;
		//Pass the pakcet to the depacketizer
		 MediaFrame* frame = depacketizer->AddPacket(packet);
		 
		 //If we have a new frame
		 if (frame)
		 {
			 //Call all listeners
			 for (Listeners::const_iterator it = listeners.begin();it!=listeners.end();++it)
				 //Call listener
				 (*it)->onMediaFrame(packet->GetSSRC(),*frame);
			 //Next
			 depacketizer->ResetFrame();
		 }
		
			
	}
	
	void AddMediaListener(MediaFrame::Listener *listener)
	{
		//Add to set
		listeners.insert(listener);
	}
	void RemoveMediaListener(MediaFrame::Listener *listener)
	{
		//Remove from set
		listeners.erase(listener);
	}
	
private:
	typedef std::set<MediaFrame::Listener*> Listeners;
private:
	Listeners listeners;
	RTPDepacketizer* depacketizer;
	RTPIncomingSourceGroup* incomingSource;
};


class RTPSessionFacade : 	
	public RTPSender,
	public RTPReceiver,
	public RTPSession
{
public:
	RTPSessionFacade(MediaFrame::Type media) : RTPSession(media,NULL)
	{
		
	}
	virtual ~RTPSessionFacade()
	{
		
	}
	
	virtual int Send(RTPPacket &packet)
	{
		
	}
	virtual int SendPLI(DWORD ssrc)
	{
		return RequestFPU();
	}
	
	int Init(const Properties &properties)
	{
		RTPMap rtp;
		
		//Get codecs
		std::vector<Properties> codecs;
		properties.GetChildrenArray("codecs",codecs);

		//For each codec
		for (auto it = codecs.begin(); it!=codecs.end(); ++it)
		{
			
			BYTE codec;
			//Depending on the type
			switch (GetMediaType())
			{
				case MediaFrame::Audio:
					codec = (BYTE)AudioCodec::GetCodecForName(it->GetProperty("codec"));
					break;
				case MediaFrame::Video:
					codec = (BYTE)VideoCodec::GetCodecForName(it->GetProperty("codec"));
					break;
				case MediaFrame::Text:
					codec = (BYTE)-1;
					break;
			}

			//Get codec type
			BYTE type = it->GetProperty("pt",0);
			//ADD it
			rtp[type] = codec;
		}
	
		//Set local 
		RTPSession::SetSendingRTPMap(rtp);
		RTPSession::SetReceivingRTPMap(rtp);
		
		//Call parent
		return RTPSession::Init();
	}
	
	virtual void onRTPPacket(BYTE* buffer, DWORD size)
	{
		RTPSession::onRTPPacket(buffer,size);
		RTPIncomingSourceGroup* incoming = GetIncomingSourceGroup();
		RTPPacket* ordered;
		//FOr each ordered packet
		while(ordered=GetOrderPacket())
			//Call listeners
			incoming->onRTP(ordered);
	}
};

%}
%include "stdint.i"
%include "../media-server/include/config.h"	
%include "../media-server/include/media.h"
%include "../media-server/include/rtp.h"
%include "../media-server/include/DTLSICETransport.h"
%include "../media-server/include/RTPBundleTransport.h"
%include "../media-server/include/mp4recorder.h"


class StringFacade : private std::string
{
public:
	StringFacade(const char* str);
	StringFacade(std::string &str);
	const char* toString();
};

class PropertiesFacade : private Properties
{
public:
	void SetProperty(const char* key,int intval);
	void SetProperty(const char* key,const char* val);
};

class MediaServer
{
public:
	static void Initialize();
	static void EnableDebug(bool flag);
	static void EnableUltraDebug(bool flag);
	static StringFacade GetFingerprint();
};


class StreamTransponder : 
	public RTPIncomingSourceGroup::Listener,
	public RTPOutgoingSourceGroup::Listener
{
public:
	StreamTransponder(RTPIncomingSourceGroup* incomingSource, RTPReceiver* incomingTransport, RTPOutgoingSourceGroup* outgoingSource,RTPSender* outgoingTransport);
	virtual ~StreamTransponder();
	virtual void onRTP(RTPIncomingSourceGroup* group,RTPPacket* packet);
	virtual void onPLIRequest(RTPOutgoingSourceGroup* group,DWORD ssrc);
	void SelectLayer(int spatialLayerId,int temporalLayerId);
};

class StreamTrackDepacketizer :
	public RTPIncomingSourceGroup::Listener
{
public:
	StreamTrackDepacketizer(RTPIncomingSourceGroup* incomingSource);
	virtual ~StreamTrackDepacketizer();
	//SWIG doesn't support inner classes, so specializing it here, it will be casted internally later
	void AddMediaListener(MP4Recorder* listener);
	void RemoveMediaListener(MP4Recorder* listener);
};

class RTPSessionFacade :
	public RTPSender,
	public RTPReceiver
{
public:
	RTPSessionFacade(MediaFrame::Type media);
	int Init(const Properties &properties);
	int SetLocalPort(int recvPort);
	int GetLocalPort();
	int SetRemotePort(char *ip,int sendPort);
	RTPOutgoingSourceGroup* GetOutgoingSourceGroup();
	RTPIncomingSourceGroup* GetIncomingSourceGroup();
	int End();
	virtual int Send(RTPPacket &packet);
	virtual int SendPLI(DWORD ssrc);
};

